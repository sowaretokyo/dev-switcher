import Foundation

/// Supabaseスタックの観測・起動・対象限定停止（`ManagedStackDriver`の Supabase 実装）。
///
/// 「Dockerの読み取り」と「CLIの実行」を組み合わせ、最後の実測値を表示用に保持する。
/// 停止権限は保持せず、誰を停止してよいかは呼び出し側の管理関係が決める。
public actor SupabaseStackDriver: ManagedStackDriver {
    public struct Options: Sendable {
        /// `start`後に`running`を待つ上限。
        public var startConfirmationWindow: Duration
        /// `stop`後に`notRunning`を待つ上限。
        public var stopConfirmationWindow: Duration
        public var pollInterval: Duration

        public init(
            startConfirmationWindow: Duration = .seconds(60),
            stopConfirmationWindow: Duration = .seconds(60),
            pollInterval: Duration = .milliseconds(250)
        ) {
            self.startConfirmationWindow = startConfirmationWindow
            self.stopConfirmationWindow = stopConfirmationWindow
            self.pollInterval = pollInterval
        }
    }

    /// Supabase CLIの実行境界で守る規則。すべての CLI 実行に渡す。
    ///
    /// `--all`と`--no-backup`はコマンド生成側に加えて実行境界でも拒否する。
    /// `SUPABASE_WORKDIR`を除くのは、対象を CommandSpec の cwd と明示的な`--workdir`だけで決めるため。
    static let commandPolicy = ManagedStackCommandPolicy(
        forbiddenArguments: SupabaseStackConfiguration.forbiddenStopOptions,
        removedEnvironmentKeys: ["SUPABASE_WORKDIR"]
    )

    public nonisolated let type: ManagedStackType = .supabase

    private let inventory: any SupabaseInventoryProbing
    private let runner: any ManagedStackCommandRunning
    private let options: Options
    private var nextLogID: UInt64 = 0
    public private(set) var latestSnapshot: ManagedStackSnapshot?

    public init(
        inventory: any SupabaseInventoryProbing,
        runner: any ManagedStackCommandRunning,
        options: Options = Options()
    ) {
        self.inventory = inventory
        self.runner = runner
        self.options = options
    }

    /// 全スタックを実測する。
    ///
    /// `known`は設定ディレクトリが分かっているスタック。DBコンテナがhealthyでも、
    /// 設定ディレクトリが既知なら対象workdirの`supabase status`成功まで確認する。
    /// Dockerを読めない場合は、未登録IDも含めて`unknown`として扱う。
    public func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot {
        let snapshot = await inspect(known: Self.configurations(known))
        latestSnapshot = snapshot
        return snapshot
    }

    /// 1スタックだけの再観測。全スタックを実測したうえで対象を取り出す。
    func observe(
        _ identity: ManagedStackIdentity,
        known: [ResolvedManagedStack]
    ) async -> ManagedStackObservation {
        await observe(known: known).observation(of: identity)
    }

    /// 対象を起動し、`running`になるまで再観測する。
    public func start(
        _ stack: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine] {
        let configuration = Self.configuration(of: stack)
        return try await executeAndConfirm(
            configuration.derived.start,
            action: L10n.text("開始"),
            identity: stack.identity,
            known: known,
            expected: .running,
            window: options.startConfirmationWindow
        )
    }

    /// 対象`project_id`だけを停止し、`notRunning`になるまで再観測する。
    /// `--all`と`--no-backup`は生成できないため、他プロジェクトを巻き込まない。
    /// 未登録スタックの停止にも、`context`の CLI 呼び出し形式を使う。
    public func stop(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine] {
        // 変換できない ID では停止コマンドを組み立てず、そのまま失敗させる。
        let projectID = try SupabaseProjectID(identity: identity)
        return try await executeAndConfirm(
            Self.configuration(of: context).derived.stopCommand(projectID: projectID),
            action: L10n.text("停止"),
            identity: identity,
            known: known,
            expected: .notRunning,
            window: options.stopConfirmationWindow
        )
    }

    // MARK: - 観測

    private static func configuration(of stack: ResolvedManagedStack) -> SupabaseResolvedConfiguration {
        switch stack.configuration {
        case let .supabase(configuration): configuration
        case .dockerCompose: preconditionFailure(L10n.text("Supabase driver に Compose 設定は渡せません。"))
        }
    }

    private static func configurations(
        _ known: [ResolvedManagedStack]
    ) -> [SupabaseProjectID: SupabaseDerivedConfiguration] {
        var result: [SupabaseProjectID: SupabaseDerivedConfiguration] = [:]
        for stack in known where stack.type == .supabase {
            let configuration = configuration(of: stack)
            result[configuration.projectID] = configuration.derived
        }
        return result
    }

    private func inspect(
        known: [SupabaseProjectID: SupabaseDerivedConfiguration]
    ) async -> ManagedStackSnapshot {
        switch await inventory.containers() {
        case let .unobservable(reason):
            return ManagedStackSnapshot(type: .supabase, unobservable: reason)
        case let .observed(containers):
            var observations: [ManagedStackObservation] = []
            for (projectID, container) in containers {
                let identity = ManagedStackIdentity(projectID)
                switch container {
                case .databaseHealthy:
                    guard let configuration = known[projectID] else {
                        // 設定ディレクトリが不明な外部スタックは、DBの実測だけで稼働中とする。
                        observations.append(
                            ManagedStackObservation(identity: identity, state: .running)
                        )
                        continue
                    }
                    observations.append(
                        await statusConfirmedObservation(
                            identity: identity,
                            configuration: configuration
                        )
                    )
                case let .degraded(reason):
                    observations.append(
                        ManagedStackObservation(identity: identity, state: .degraded, detail: reason)
                    )
                case let .indeterminate(reason):
                    observations.append(
                        ManagedStackObservation(identity: identity, state: .unknown, detail: reason)
                    )
                }
            }
            return ManagedStackSnapshot(type: .supabase, observations: observations)
        }
    }

    private func statusConfirmedObservation(
        identity: ManagedStackIdentity,
        configuration: SupabaseDerivedConfiguration
    ) async -> ManagedStackObservation {
        do {
            let result = try await runner.run(configuration.statusCommand, policy: Self.commandPolicy)
            guard result.isSuccess else {
                // DBはhealthyなのにstatusが失敗する状態は確定できない。停止中へ倒さない。
                return ManagedStackObservation(
                    identity: identity,
                    state: .unknown,
                    detail: L10n.text("DBコンテナはhealthyですが `supabase status` が失敗しました（\(result.status.description)）。\n")
                        + result.combinedOutput
                )
            }
            return ManagedStackObservation(identity: identity, state: .running)
        } catch {
            return ManagedStackObservation(
                identity: identity,
                state: .unknown,
                detail: L10n.text("`supabase status` を実行できません。\n\(error)")
            )
        }
    }

    // MARK: - 起動・停止

    /// 起動・停止とも、コマンドの成功と期待する状態の実測が揃って初めて成功とする。
    private func executeAndConfirm(
        _ command: CommandSpec,
        action: String,
        identity: ManagedStackIdentity,
        known: [ResolvedManagedStack],
        expected: ManagedStackState,
        window: Duration
    ) async throws -> [LogLine] {
        let result: ManagedStackCommandResult
        do {
            result = try await runner.run(command, policy: Self.commandPolicy)
        } catch {
            throw ManagedStackOperationError.commandUnavailable(
                action: action,
                identity: identity,
                reason: "\(error)"
            )
        }
        let logs = logLines(result)
        guard result.isSuccess else {
            throw ManagedStackOperationError.commandFailed(
                action: action,
                identity: identity,
                status: result.status,
                output: tail(result.combinedOutput)
            )
        }

        let observation = await waitForState(
            expected,
            identity: identity,
            known: known,
            window: window
        )
        guard observation.state == expected else {
            throw ManagedStackOperationError.stateNotConfirmed(
                action: action,
                identity: identity,
                expected: expected,
                actual: observation.state,
                detail: observation.detail
            )
        }
        return logs
    }

    private func waitForState(
        _ expected: ManagedStackState,
        identity: ManagedStackIdentity,
        known: [ResolvedManagedStack],
        window: Duration
    ) async -> ManagedStackObservation {
        let deadline = ContinuousClock.now + window
        var latest = await observe(identity, known: known)
        while latest.state != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: options.pollInterval)
            latest = await observe(identity, known: known)
        }
        return latest
    }

    // MARK: - ログ

    private func logLines(_ result: ManagedStackCommandResult) -> [LogLine] {
        let now = Date()
        var lines: [LogLine] = []
        lines += logLines(result.standardOutput, stream: .stdout, timestamp: now)
        lines += logLines(result.standardError, stream: .stderr, timestamp: now)
        return lines
    }

    private func logLines(
        _ text: String,
        stream: LogLine.Stream,
        timestamp: Date
    ) -> [LogLine] {
        text.split(whereSeparator: \.isNewline).map { part in
            defer { nextLogID += 1 }
            return LogLine(
                id: nextLogID,
                timestamp: timestamp,
                stream: stream,
                text: sanitized(String(part))
            )
        }
    }

    private func tail(_ text: String, lineLimit: Int = 12) -> String {
        text.split(whereSeparator: \.isNewline)
            .suffix(lineLimit)
            .map(String.init)
            .joined(separator: "\n")
    }

    /// SwiftUI/NSTextViewはANSI CSIを解釈せず、ESCだけを落として`[31m`を表示する。
    private func sanitized(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}
