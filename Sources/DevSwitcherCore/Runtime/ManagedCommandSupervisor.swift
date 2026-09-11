import Foundation

public enum SupabaseOperationError: Error, Equatable, Sendable, CustomStringConvertible {
    case commandFailed(
        action: String,
        projectID: SupabaseProjectID,
        status: ExitStatus,
        output: String
    )
    case commandUnavailable(action: String, projectID: SupabaseProjectID, reason: String)
    case stateNotConfirmed(
        action: String,
        projectID: SupabaseProjectID,
        expected: SupabaseStackState,
        actual: SupabaseStackState,
        detail: String?
    )

    public var description: String {
        switch self {
        case let .commandFailed(action, projectID, status, output):
            let head = "Supabase「\(projectID)」の\(action)コマンドが失敗しました（\(status.description)）。"
            return output.isEmpty ? head : head + "\n直近の出力:\n" + output
        case let .commandUnavailable(action, projectID, reason):
            return "Supabase「\(projectID)」の\(action)コマンドを実行できません。\n\(reason)"
        case let .stateNotConfirmed(action, projectID, expected, actual, detail):
            let head = "Supabase「\(projectID)」の\(action)後に\(expected.label)を確認できませんでした（実測: \(actual.label)）。"
            return detail.map { head + "\n\($0)" } ?? head
        }
    }
}

/// Supabaseスタックの観測・起動・対象限定停止をまとめる。
///
/// 「Dockerの読み取り」と「CLIの実行」を組み合わせ、最後の実測値を表示用に保持する。
/// 停止権限は保持せず、誰を停止してよいかは呼び出し側の管理関係が決める。
public actor SupabaseStackController {
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

    private let inventory: any SupabaseInventoryProbing
    private let runner: any SupabaseCommandRunning
    private let options: Options
    private var nextLogID: UInt64 = 0
    public private(set) var latestSnapshot: SupabaseStackSnapshot?

    public init(
        inventory: any SupabaseInventoryProbing,
        runner: any SupabaseCommandRunning,
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
    public func observe(
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async -> SupabaseStackSnapshot {
        let snapshot = await inspect(known: known)
        latestSnapshot = snapshot
        return snapshot
    }

    private func inspect(
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async -> SupabaseStackSnapshot {
        switch await inventory.containers() {
        case let .unobservable(reason):
            return SupabaseStackSnapshot(unobservable: reason)
        case let .observed(containers):
            var observations: [SupabaseStackObservation] = []
            for (projectID, container) in containers {
                switch container {
                case .databaseHealthy:
                    guard let configuration = known[projectID] else {
                        // 設定ディレクトリが不明な外部スタックは、DBの実測だけで稼働中とする。
                        observations.append(
                            SupabaseStackObservation(projectID: projectID, state: .running)
                        )
                        continue
                    }
                    observations.append(
                        await statusConfirmedObservation(
                            projectID: projectID,
                            configuration: configuration
                        )
                    )
                case let .degraded(reason):
                    observations.append(
                        SupabaseStackObservation(
                            projectID: projectID,
                            state: .degraded,
                            detail: reason
                        )
                    )
                case let .indeterminate(reason):
                    observations.append(
                        SupabaseStackObservation(
                            projectID: projectID,
                            state: .unknown,
                            detail: reason
                        )
                    )
                }
            }
            return SupabaseStackSnapshot(observations)
        }
    }

    private func statusConfirmedObservation(
        projectID: SupabaseProjectID,
        configuration: SupabaseServiceConfiguration
    ) async -> SupabaseStackObservation {
        do {
            let result = try await runner.run(configuration.statusCommand)
            guard result.isSuccess else {
                // DBはhealthyなのにstatusが失敗する状態は確定できない。停止中へ倒さない。
                return SupabaseStackObservation(
                    projectID: projectID,
                    state: .unknown,
                    detail: "DBコンテナはhealthyですが `supabase status` が失敗しました（\(result.status.description)）。\n"
                        + result.combinedOutput
                )
            }
            return SupabaseStackObservation(projectID: projectID, state: .running)
        } catch {
            return SupabaseStackObservation(
                projectID: projectID,
                state: .unknown,
                detail: "`supabase status` を実行できません。\n\(error)"
            )
        }
    }

    /// 対象を起動し、`running`になるまで再観測する。
    public func start(
        configuration: SupabaseServiceConfiguration,
        projectID: SupabaseProjectID,
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async throws -> [LogLine] {
        try await executeAndConfirm(
            configuration.start,
            action: "開始",
            projectID: projectID,
            known: known,
            expected: .running,
            window: options.startConfirmationWindow
        )
    }

    /// 対象`project_id`だけを停止し、`notRunning`になるまで再観測する。
    /// `--all`と`--no-backup`は生成できないため、他プロジェクトを巻き込まない。
    public func stop(
        using configuration: SupabaseServiceConfiguration,
        projectID: SupabaseProjectID,
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async throws -> [LogLine] {
        try await executeAndConfirm(
            configuration.stopCommand(projectID: projectID),
            action: "停止",
            projectID: projectID,
            known: known,
            expected: .notRunning,
            window: options.stopConfirmationWindow
        )
    }

    /// 起動・停止とも、コマンドの成功と期待する状態の実測が揃って初めて成功とする。
    private func executeAndConfirm(
        _ command: CommandSpec,
        action: String,
        projectID: SupabaseProjectID,
        known: [SupabaseProjectID: SupabaseServiceConfiguration],
        expected: SupabaseStackState,
        window: Duration
    ) async throws -> [LogLine] {
        let result: SupabaseCommandResult
        do {
            result = try await runner.run(command)
        } catch {
            throw SupabaseOperationError.commandUnavailable(
                action: action,
                projectID: projectID,
                reason: "\(error)"
            )
        }
        let logs = logLines(result)
        guard result.isSuccess else {
            throw SupabaseOperationError.commandFailed(
                action: action,
                projectID: projectID,
                status: result.status,
                output: tail(result.combinedOutput)
            )
        }

        let observation = await waitForState(
            expected,
            projectID: projectID,
            known: known,
            window: window
        )
        guard observation.state == expected else {
            throw SupabaseOperationError.stateNotConfirmed(
                action: action,
                projectID: projectID,
                expected: expected,
                actual: observation.state,
                detail: observation.detail
            )
        }
        return logs
    }

    /// 1スタックだけの再観測。
    public func observe(
        projectID: SupabaseProjectID,
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async -> SupabaseStackObservation {
        let snapshot = await observe(known: known)
        return snapshot.observation(of: projectID)
    }

    private func waitForState(
        _ expected: SupabaseStackState,
        projectID: SupabaseProjectID,
        known: [SupabaseProjectID: SupabaseServiceConfiguration],
        window: Duration
    ) async -> SupabaseStackObservation {
        let deadline = ContinuousClock.now + window
        var latest = await observe(projectID: projectID, known: known)
        while latest.state != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: options.pollInterval)
            latest = await observe(projectID: projectID, known: known)
        }
        return latest
    }

    private func logLines(_ result: SupabaseCommandResult) -> [LogLine] {
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

/// 1つのSupabaseサービスに対する管理handle。
///
/// 停止してよいかどうかは、実測状態ではなくここに登録された管理関係が決める。
/// 実測結果は明示的な再観測でのみ更新する（MVPでは定期ポーリングを行わない）。
actor ManagedCommandSupervisor {
    let configuration: SupabaseServiceConfiguration
    let projectID: SupabaseProjectID
    let relationship: SupabaseManagementRelationship

    private let controller: SupabaseStackController
    private(set) var observation: SupabaseStackObservation
    private var continuation: AsyncStream<ServiceSupervisor.Event>.Continuation?

    init(
        configuration: SupabaseServiceConfiguration,
        projectID: SupabaseProjectID,
        relationship: SupabaseManagementRelationship,
        observation: SupabaseStackObservation,
        controller: SupabaseStackController
    ) {
        self.configuration = configuration
        self.projectID = projectID
        self.relationship = relationship
        self.observation = observation
        self.controller = controller
    }

    /// 稼働中と言えるのは`running`だけ。`degraded`と`unknown`は起動済みにしない。
    var isRunning: Bool { observation.state == .running }

    /// 停止導線を出すかどうか。観測できないスタックを「居ない」と決めつけない。
    var isOccupyingResources: Bool { observation.state != .notRunning }

    func makeEventStream() -> AsyncStream<ServiceSupervisor.Event> {
        let (stream, continuation) = AsyncStream<ServiceSupervisor.Event>.makeStream(
            of: ServiceSupervisor.Event.self,
            bufferingPolicy: .unbounded
        )
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    func emit(logs: [LogLine]) {
        guard !logs.isEmpty else { return }
        continuation?.yield(.log(logs))
    }

    func update(observation: SupabaseStackObservation) {
        self.observation = observation
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    /// 管理関係のあるスタックだけを、対象限定の`stop`で停止する。
    func stop(
        known: [SupabaseProjectID: SupabaseServiceConfiguration]
    ) async throws -> ServiceStopOutcome {
        do {
            let logs = try await controller.stop(
                using: configuration,
                projectID: projectID,
                known: known
            )
            emit(logs: logs)
            observation = SupabaseStackObservation(projectID: projectID, state: .notRunning)
            continuation?.yield(
                .exited(status: .exited(code: 0), requestedByUser: true, startupConfirmed: false)
            )
            finishEvents()
            return .stopped(nil)
        } catch {
            // 停止できたかどうかを終了コードだけで決めない。実測し直して状態を残す。
            observation = await controller.observe(projectID: projectID, known: known)
            throw error
        }
    }
}
