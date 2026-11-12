import Darwin
import Foundation

/// サービス1件分の観測。起動直後の異常終了と、失敗画面へ出す末尾ログを持つ。
actor ServiceObservation {
    struct ExitRecord: Equatable, Sendable {
        let status: ExitStatus
        let requestedByUser: Bool
    }

    private(set) var exit: ExitRecord?
    private var tail: [LogLine] = []
    private var startupConfirmed = false
    /// 失敗シートに出す行数（docs/SPEC.md 10）。stdout と stderr を時系列のまま保つ。
    private static let tailLimit = 6

    /// 起動確認との順序をactor内で確定し、終了イベントへ確認結果を付けて返す。
    func record(_ event: ServiceSupervisor.Event) -> ServiceSupervisor.Event {
        switch event {
        case let .log(lines):
            tail.append(contentsOf: lines)
            if tail.count > Self.tailLimit {
                tail.removeFirst(tail.count - Self.tailLimit)
            }
        case let .exited(status, requestedByUser, _):
            if exit == nil {
                exit = ExitRecord(status: status, requestedByUser: requestedByUser)
            }
            return .exited(
                status: status,
                requestedByUser: requestedByUser,
                startupConfirmed: startupConfirmed
            )
        case .logSessionStarted, .started, .ports, .warning, .logUnavailable:
            break
        }
        return event
    }

    /// 終了記録が無い場合だけ、初期観測を通過した事実を確定する。
    func confirmStartup() -> Bool {
        guard exit == nil else { return false }
        startupConfirmed = true
        return true
    }

    var tailLines: [LogLine] { tail }

    var tailText: String {
        tail.map { "\($0.stream == .stderr ? "E" : " ") \($0.text)" }.joined(separator: "\n")
    }
}

/// プロジェクトの停止・ゲート・起動を1本の直列処理として扱う。
///
/// ゲートは1つだけ。切替元が実際に握っていたポートの解放を確認するまで、
/// 起動フェーズへ入れない構造にしてある（docs/SPEC.md 16.2 I-3）。判定のソースは実測だけで、
/// 切替先の設定ポートは起動可否の根拠にしない。ポートの取得は OS の先勝に任せる。
/// 同時に2つの切替を開始できないよう、actor に加えて明示的なフラグでも守る
/// （actor は `await` をまたいだ再入を防がないため）。
public actor SwitchCoordinator {
    /// サービスのログや状態変化をUIへ流すための出口。
    public typealias EventSink = @Sendable (UUID, ServiceSupervisor.Event) -> Void
    public typealias ProgressSink = @Sendable (SwitchState) -> Void
    /// ポート占有の実測。テストで lsof に依存しないよう差し替え可能にする。
    public typealias PortHolderProbe = @Sendable ([Int]) async throws -> [ObservedPortHolder]

    private struct RestartRecovery: Sendable {
        let portsToRelease: [Int]
        var failureReason: String?
    }

    public struct Options: Sendable {
        /// 停止元のポート解放を待つ上限。
        public var releaseTimeout: Duration
        /// 停止時に通常終了を待つ猶予。
        public var stopGrace: Duration
        /// 起動直後の観測時間。
        public var startupObservationWindow: Duration
        public var startupPollInterval: Duration
        /// ポート解放ゲートのポーリング間隔。
        public var gatePollInterval: Duration

        public init(
            releaseTimeout: Duration = .seconds(20),
            stopGrace: Duration = .seconds(10),
            startupObservationWindow: Duration = StartupObservationPolicy.defaultObservationWindow,
            startupPollInterval: Duration = StartupObservationPolicy.defaultPollInterval,
            gatePollInterval: Duration = .milliseconds(200)
        ) {
            self.releaseTimeout = releaseTimeout
            self.stopGrace = stopGrace
            self.startupObservationWindow = startupObservationWindow
            self.startupPollInterval = startupPollInterval
            self.gatePollInterval = gatePollInterval
        }
    }

    private let registry: RuntimeRegistry
    private let portHolderProbe: PortHolderProbe
    private let options: Options
    private let currentUserName: String

    private var inFlight = false
    private var cancelRequested = false
    private var enteredStartPhase = false

    /// 起動確認を通過したサービス。起動直後で観測が終わっていないものと区別する。
    private var startedServiceIDs: Set<UUID> = []
    private var failureReasons: [UUID: String] = [:]
    private var residualGroups: [UUID: pid_t] = [:]
    /// 単体再起動で対象を停止した後の再開地点。
    /// ポートと失敗理由を一体で持ち、通常の未起動サービスと区別する。
    private var restartRecoveries: [UUID: RestartRecovery] = [:]
    /// 今回引き継いだ管理対象スタック。今回起動した分と違い、巻き戻しの対象にしない。
    private var adoptedServiceIDs: Set<UUID> = []
    /// 巻き戻し後も稼働したまま残った引き継ぎ分。停止導線を残すため残存として表示する。
    private var residualManagedServiceIDs: Set<UUID> = []
    private var observations: [UUID: ServiceObservation] = [:]
    private var consumers: [UUID: Task<Void, Never>] = [:]

    public init(
        registry: RuntimeRegistry,
        portHolderProbe: @escaping PortHolderProbe = { ports in
            try await PortInspector.holders(ofPorts: ports)
        },
        options: Options = Options(),
        currentUserName: String = NSUserName()
    ) {
        self.registry = registry
        self.portHolderProbe = portHolderProbe
        self.options = options
        self.currentUserName = currentUserName
    }

    // MARK: - 中止

    /// 起動フェーズへ入る前だけ受け付ける（docs/SPEC.md 16.2 I-4）。
    /// 中止しても切替元の停止は最後まで実行する。SIGTERM 済みのプロセスは取り消せない。
    @discardableResult
    public func cancel() -> Bool {
        guard inFlight, !enteredStartPhase else { return false }
        cancelRequested = true
        return true
    }

    public var isRunningOperation: Bool { inFlight }

    public var canCancel: Bool { inFlight && !enteredStartPhase }

    // MARK: - 入口

    /// プロジェクトを起動する（切替元なし）。
    ///
    /// `registeredProjects`はスタックIDの一意性確認と、既存スタックの登録有無の表示に使う。
    /// `approval`は利用者が確認シートで承認した内容。承認前は既存スタックを変更しない。
    public func start(
        _ project: ProjectDefinition,
        registeredProjects: [ProjectDefinition] = [],
        approval: ManagedStackApproval? = nil,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: nil,
            starting: project,
            registeredProjects: registeredProjects,
            approval: approval,
            progress: progress,
            events: events
        )
    }

    /// プロジェクトを停止する（切替先なし）。
    public func stop(
        _ project: ProjectDefinition,
        registeredProjects: [ProjectDefinition] = [],
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: project,
            starting: nil,
            registeredProjects: registeredProjects,
            approval: nil,
            progress: progress,
            events: events
        )
    }

    /// 切替。停止 → ポート解放の確認 → 起動の順を崩さない。
    public func switchProject(
        from source: ProjectDefinition,
        to target: ProjectDefinition,
        registeredProjects: [ProjectDefinition] = [],
        approval: ManagedStackApproval? = nil,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: source,
            starting: target,
            registeredProjects: registeredProjects,
            approval: approval,
            progress: progress,
            events: events
        )
    }

    /// 起動済みプロジェクトへ通常プロセス1件を追加する。保存済みの起動対象は変更しない。
    @discardableResult
    public func startService(
        _ service: LaunchUnit,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> ProjectFact {
        try await runServiceOperation(service, in: project, restarting: false, progress: progress, events: events)
    }

    /// 起動済みプロジェクトの通常プロセス1件だけを再起動する。
    ///
    /// プロジェクト全体の起動順を再実行せず、対象の停止、実測ポートの解放確認、
    /// 起動直後の観測だけを同じ排他境界で行う。管理対象スタックは専用lifecycleを持つため対象外。
    @discardableResult
    public func restart(
        _ service: LaunchUnit,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> ProjectFact {
        try await runServiceOperation(service, in: project, restarting: true, progress: progress, events: events)
    }

    /// 追加起動と再起動で、初期観測・ログ・失敗時の停止を共有する。
    private func runServiceOperation(
        _ service: LaunchUnit,
        in project: ProjectDefinition,
        restarting: Bool,
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws -> ProjectFact {
        guard !inFlight else {
            throw SwitchFailure(
                reason: .operationInProgress,
                facts: await facts(source: project, target: nil)
            )
        }
        inFlight = true
        defer { inFlight = false }

        guard project.entry(id: service.id) == service else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "サービス「\(service.name)」の設定がプロジェクト「\(project.name)」の登録内容と一致しません。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        if case let .stack(definition, _) = service {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "\(definition.type.displayName)は通常プロセスと停止・状態確認の方法が異なるため、単体の起動・再起動はできません。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        guard await registry.occupyingServiceIDs(projectID: project.id).isEmpty == false else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "プロジェクト「\(project.name)」は停止中です。プロジェクト単位で起動してください。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }

        // 設定上は対象外でも、今回追加起動・引き継ぎしたプロセスは再起動できる。
        let phase = await servicePhase(service, in: project)
        let canRun: Bool
        switch phase {
        case .excluded, .stopped:
            canRun = !restarting
        case .running, .healthy, .failed, .residual:
            canRun = restarting
        case .starting, .stopping:
            canRun = false
        }
        guard canRun else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    restarting
                        ? "サービス「\(service.name)」は起動対象から外れています。未起動のプロセスには「起動」を使ってください。"
                        : "サービス「\(service.name)」は追加起動できる状態ではありません。動作中または失敗したプロセスには再起動を使ってください。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }

        let spec: StartupObservationSpec
        do {
            spec = try StartupObservationPolicy.spec(
                for: try Self.process(service),
                observationWindow: options.startupObservationWindow,
                pollInterval: options.startupPollInterval
            )
        } catch {
            throw SwitchFailure(
                reason: .unsupportedConfiguration("\(error)"),
                facts: await facts(source: project, target: nil)
            )
        }

        let restartRecovery: RestartRecovery?
        if restarting, await registry.occupiedProcessGroup(serviceID: service.id) != nil {
            let ports = try await stopForRestart(service, in: project, progress: progress)
            let recovery = RestartRecovery(portsToRelease: ports, failureReason: nil)
            restartRecoveries[service.id] = recovery
            restartRecovery = recovery
        } else {
            restartRecovery = restarting ? restartRecoveries[service.id] : nil
        }

        if var restartRecovery {
            do {
                try await releaseGate(
                    ports: restartRecovery.portsToRelease,
                    source: project,
                    target: nil,
                    progress: progress
                )
            } catch let failure as SwitchFailure {
                // 対象は停止済みでも、通常の未起動ではない。失敗として表示し、
                // 同じサービスの再起動を再試行できる状態を維持する。
                restartRecovery.failureReason = failure.reason.detail
                restartRecoveries[service.id] = restartRecovery
                throw SwitchFailure(
                    reason: failure.reason,
                    facts: await facts(source: project, target: nil)
                )
            }
            restartRecoveries[service.id] = nil
        }

        progress(.starting(service: service.name, index: 1, total: 1))
        consumers[service.id]?.cancel()
        events(service.id, .logSessionStarted)

        let observation = ServiceObservation()
        do {
            let stream = try await registry.start(service: service, in: project)
            observations[service.id] = observation
            consumers[service.id] = Task {
                for await event in stream {
                    let observedEvent = await observation.record(event)
                    events(service.id, observedEvent)
                }
            }
            failureReasons[service.id] = nil
            residualGroups[service.id] = nil
        } catch {
            throw await serviceStartFailure(error, service: service, project: project)
        }

        progress(.observingStartup(service: service.name))
        switch await awaitStartupObservation(service: service, spec: spec) {
        case .passed:
            startedServiceIDs.insert(service.id)
            failureReasons[service.id] = nil
            progress(.completed)
            return await projectFact(project)
        case let .failed(reason):
            await stopAfterFailedStart(service)
            failureReasons[service.id] = reason
            startedServiceIDs.remove(service.id)
            throw SwitchFailure(
                reason: .startFailed(service: service.name, reason: reason),
                facts: await facts(source: nil, target: project)
            )
        }
    }

    /// 追加起動・再起動後の手掛かりを保存できなかった場合に、今回起動した1件だけを戻す。
    /// UIから通常の単体停止としては公開しない。
    public func stopAfterUnsavedServiceStart(
        _ service: LaunchUnit,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in }
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        guard project.entry(id: service.id) != nil else {
            throw RuntimeError.notRunning(service: service.name)
        }
        guard await registry.occupiedProcessGroup(serviceID: service.id) != nil else {
            clearState(of: service.id)
            return
        }

        progress(.stopping(service: service.name, index: 1, total: 1))
        try await stopOne(service, in: project)
        await clearProjectStateIfFullyStopped(project)
    }

    /// 起動後の保存失敗では、今回起動したサービスだけを補償停止する。
    /// 引き継いだ管理対象スタックと操作前から管理していた対象は、明示停止のために残す。
    public func stopAfterUnsavedStart(
        _ project: ProjectDefinition,
        preserving previouslyManagedIDs: Set<UUID>,
        progress: @escaping ProgressSink = { _ in }
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        var preserved = previouslyManagedIDs
        for serviceID in await registry.occupyingServiceIDs(projectID: project.id) {
            let relationship = await registry.managedRelationship(stackID: serviceID)
            if relationship == .adopted || relationship == .restored {
                preserved.insert(serviceID)
                residualManagedServiceIDs.insert(serviceID)
            }
        }
        let ports = try await stopPhase(
            project, target: nil, excluding: preserved, progress: progress
        )
        try await releaseGate(ports: ports, source: project, target: nil, progress: progress)
    }

    // MARK: - 本体

    private func run(
        stopping source: ProjectDefinition?,
        starting target: ProjectDefinition?,
        registeredProjects: [ProjectDefinition],
        approval: ManagedStackApproval?,
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws -> SwitchOutcome {
        guard !inFlight else {
            throw SwitchFailure(
                reason: .operationInProgress,
                facts: CurrentStateFacts(
                    source: source.map { ProjectFact(
                        projectID: $0.id,
                        projectName: $0.name,
                        phase: .switching,
                        services: []
                    ) },
                    target: target.map { ProjectFact(
                        projectID: $0.id,
                        projectName: $0.name,
                        phase: .switching,
                        services: []
                    ) }
                )
            )
        }
        inFlight = true
        cancelRequested = false
        enteredStartPhase = false
        defer {
            inFlight = false
            enteredStartPhase = false
            cancelRequested = false
        }

        // 登録済みの管理対象スタックのIDを毎回解決し直す。観測の基準もここで入れ替える。
        let stackResolution = resolveManagedStacks(
            registeredProjects: registeredProjects,
            source: source,
            target: target
        )
        await registry.setKnownStacks(stackResolution.stacks)
        // 起動・停止・切替の直前に実測し直す。保存済みの表示値のまま停止判断をしない。
        await refreshManagedObservations()
        // 解決できない、または重複するIDがあれば新しい起動・切替はしない。
        // 単独停止は復旧手段なので、この理由では止めない。
        if target != nil, !stackResolution.errors.isEmpty {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    stackResolution.errorHeadline + "\n"
                        + stackResolution.errors.joined(separator: "\n")
                ),
                facts: await facts(source: source, target: target)
            )
        }

        // 起動前の検証。実行できない設定は、停止を始める前に落とす。
        // 停止してから「起動できません」と言うと、どちらも動いていない状態を作る。
        if let target, let failure = await preflight(target, source: source) {
            throw failure
        }

        // 既存スタックの実測と確認は、切替元・切替先のどちらも変更する前に行う。
        var stackPlan: ManagedStackExecutionPlan?
        if let target {
            stackPlan = try await resolveManagedStackPlan(
                target: target,
                source: source,
                resolution: stackResolution,
                approval: approval
            )
        }

        var portsToRelease: [Int] = []
        if let source {
            portsToRelease = try await stopPhase(source, target: target, progress: progress)
        }

        if let source {
            try await releaseGate(
                ports: portsToRelease,
                source: source,
                target: target,
                progress: progress
            )
        }

        try await throwIfCancelled(source: source, target: target)

        guard let target else {
            progress(.completed)
            return SwitchOutcome(
                facts: await facts(source: source, target: nil),
                degradedServices: []
            )
        }

        // ここから先は中止を受け付けない。
        enteredStartPhase = true
        if let stackPlan {
            try await executeManagedStackStops(
                stackPlan,
                source: source,
                target: target,
                resolution: stackResolution,
                progress: progress
            )
        }
        let degraded = try await startPhase(
            target,
            source: source,
            stackPlan: stackPlan,
            progress: progress,
            events: events
        )

        progress(.completed)
        return SwitchOutcome(
            facts: await facts(source: source, target: target),
            degradedServices: degraded
        )
    }

    // MARK: - 管理対象スタック

    /// 今回の起動対象に対して確定した処理内容。
    /// 確認が必要な場合は、この値を作る前に`SwitchFailure`で中断している。
    private struct ManagedStackExecutionPlan {
        struct Launch {
            let stack: ResolvedManagedStack
            /// `adopt`は起動コマンドを実行しない。`restart`は対象を停止してから起動する。
            let action: ManagedStackConfirmationTarget.Action
        }

        struct Stop {
            let identity: ManagedStackIdentity
            /// 停止コマンドの実行に使う設定。同じ種類の対象スタックの設定。
            let context: ResolvedManagedStack
        }

        /// 今回起動するスタック。起動順。
        let launches: [Launch]
        /// 起動前に停止するID。承認済みの停止行の順に続けて、`restart`の対象自身。
        let stops: [Stop]

        func launch(of stackID: UUID) -> Launch? {
            launches.first { $0.stack.stackID == stackID }
        }
    }

    /// 確認 plan と、その中の対象行・停止行。plan の`entries`は対象行（起動順）、停止行の順。
    private struct ManagedStackPlanDraft {
        let plan: ManagedStackConfirmationPlan
        /// 対象行。`makeManagedStackPlan`へ渡したスタックと同じ順。
        let targets: [ManagedStackConfirmationTarget]
        /// 停止行と、その停止に使う設定。
        let stops: [ManagedStackExecutionPlan.Stop]
    }

    /// 登録済みの管理対象スタックの設定解決結果。
    private struct ManagedStackResolution {
        var stacks: [ManagedStackIdentity: ResolvedManagedStack] = [:]
        var stacksByService: [UUID: ResolvedManagedStack] = [:]
        var owners: [ManagedStackIdentity: ManagedStackConfirmationTarget.Registration] = [:]
        var errors: [String] = []
        /// 解決できなかった、または重複したスタックの理由。`errors`の行と同じ原因を持つ。
        var unresolvedReasons: [UUID: String] = [:]
        /// エラーが出た種類。初出順。
        var errorTypes: [ManagedStackType] = []

        mutating func appendError(_ line: String, stackID: UUID, reason: String, type: ManagedStackType) {
            errors.append(line)
            unresolvedReasons[stackID] = reason
            if !errorTypes.contains(type) {
                errorTypes.append(type)
            }
        }

        /// 解決エラーの見出し。種類ごとに 1 行。
        /// 単一種類では従来の見出し（種類名と ID の呼び名から組み立てる）と同一。
        /// 複数種類が混在するときの文言は Phase B で決める。
        var errorHeadline: String {
            errorTypes
                .map { "\($0.displayName)の\($0.identityLabel)を確認できません。" }
                .joined(separator: "\n")
        }
    }

    /// 登録済みの全管理対象スタックのIDを設定ファイルから解決し、重複を検出する。
    /// 解決できないものは既定値で補わず、理由を残す。
    private func resolveManagedStacks(
        registeredProjects: [ProjectDefinition],
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) -> ManagedStackResolution {
        var seenProjectIDs: Set<UUID> = []
        var projects: [ProjectDefinition] = []
        for project in registeredProjects + [source, target].compactMap({ $0 })
        where seenProjectIDs.insert(project.id).inserted {
            projects.append(project)
        }

        var result = ManagedStackResolution()
        for project in projects {
            for unit in project.launchUnits {
                guard case let .stack(definition, workingDirectory) = unit else { continue }
                do {
                    // 構造不備は`failureReason`と同じ description、設定ファイルの読み取りエラーは
                    // 種類ごとのエラーがそのまま throw される。
                    let stack = try ResolvedManagedStack(
                        environmentID: project.id,
                        definition: definition,
                        workingDirectory: workingDirectory
                    )
                    if let owner = result.owners[stack.identity] {
                        let message = ValidationError.duplicateManagedStackIdentity(
                            identity: stack.identity,
                            otherProject: owner.environmentName
                        ).description
                        result.appendError(
                            message,
                            stackID: definition.id,
                            reason: message,
                            type: definition.type
                        )
                        continue
                    }
                    result.stacks[stack.identity] = stack
                    result.stacksByService[definition.id] = stack
                    result.owners[stack.identity] = ManagedStackConfirmationTarget.Registration(
                        environmentName: project.name,
                        stackName: definition.name,
                        directory: stack.configuration.registrationDirectory
                    )
                } catch {
                    result.appendError(
                        "「\(project.name)」の \(definition.name): \(error)",
                        stackID: definition.id,
                        reason: "\(error)",
                        type: definition.type
                    )
                }
            }
        }
        return result
    }

    /// 既存スタックを実測し、確認が要るかどうかも含めて今回の処理内容を決める。
    ///
    /// ここは変更操作の前に呼ぶ。承認済みの場合も、実行直前のこの観測結果と
    /// 承認内容（IDの集合・状態・対象設定）が一致しなければ何も変更しない。
    private func resolveManagedStackPlan(
        target: ProjectDefinition,
        source: ProjectDefinition?,
        resolution: ManagedStackResolution,
        approval: ManagedStackApproval?
    ) async throws -> ManagedStackExecutionPlan? {
        let definitions = target.enabledLaunchUnits.compactMap { unit -> ManagedStackDefinition? in
            guard case let .stack(definition, _) = unit else { return nil }
            return definition
        }
        guard !definitions.isEmpty else { return nil }
        var stacks: [ResolvedManagedStack] = []
        for definition in definitions {
            // 起動先の解決エラーは呼び出し元で中断済みのため、通常は到達しない。
            // 到達した場合も既定値で補わず、解決時の理由で止める。
            guard let stack = resolution.stacksByService[definition.id] else {
                throw SwitchFailure(
                    reason: .unsupportedConfiguration(
                        RuntimeError.managedCommandInvalid(
                            service: definition.name,
                            reason: resolution.unresolvedReasons[definition.id]
                                ?? "\(definition.type.displayName)の\(definition.type.identityLabel)を解決できていません。"
                        ).description
                    ),
                    facts: await facts(source: source, target: target)
                )
            }
            stacks.append(stack)
        }

        let draft = try await observeAndPlanManagedStacks(
            stacks,
            source: source,
            target: target,
            resolution: resolution
        )

        if draft.plan.requiresConfirmation, approval != draft.plan.approval {
            // 未承認、または承認後に対象・状態・設定が変わった。何も変更せず確認し直す。
            throw SwitchFailure(
                reason: .managedStackConfirmationRequired(plan: draft.plan),
                facts: await facts(source: source, target: target)
            )
        }

        let launches = zip(stacks, draft.targets).map { stack, entry in
            ManagedStackExecutionPlan.Launch(stack: stack, action: entry.action)
        }
        // 対象を含む承認済み全件を停止してから、対象を起動する。
        let restartStops = launches
            .filter { $0.action == .restart }
            .map { ManagedStackExecutionPlan.Stop(identity: $0.stack.identity, context: $0.stack) }
        return ManagedStackExecutionPlan(
            launches: launches,
            stops: draft.stops + restartStops
        )
    }

    /// 管理下と登録済みのスタックを再観測し、判定不能なら変更前に止めたうえで確認 plan を作る。
    private func observeAndPlanManagedStacks(
        _ stacks: [ResolvedManagedStack],
        source: ProjectDefinition?,
        target: ProjectDefinition,
        resolution: ManagedStackResolution
    ) async throws -> ManagedStackPlanDraft {
        let snapshot = await registry.observeManagedStacks()
        try await throwIfUnknown(
            snapshot,
            requiring: Set(stacks.map(\.type)),
            source: source,
            target: target
        )
        return makeManagedStackPlan(
            stacks: stacks,
            projectName: target.name,
            snapshot: snapshot,
            skippingStopFor: await managedIdentitiesStoppedWith(source),
            resolution: resolution
        )
    }

    /// 今回起動する全スタックの対象行（起動順）と、種類ごとの排他範囲に入る停止行から確認 plan を作る。
    ///
    /// 停止行を作るのは`allOfType`の種類だけで、その種類の観測済み ID のうち、対象 ID でも
    /// 切替元の管理下 ID でもないものを停止対象にする。`identityOnly`の種類は停止行を作らない。
    private func makeManagedStackPlan(
        stacks: [ResolvedManagedStack],
        projectName: String,
        snapshot: ManagedStackSnapshot,
        skippingStopFor skipped: Set<ManagedStackIdentity>,
        resolution: ManagedStackResolution
    ) -> ManagedStackPlanDraft {
        let targets = stacks.map { stack -> ManagedStackConfirmationTarget in
            let state = snapshot.state(of: stack.identity)
            let action: ManagedStackConfirmationTarget.Action
            switch state {
            case .running: action = .adopt
            case .degraded: action = .restart
            case .notRunning, .unknown: action = .start
            }
            return ManagedStackConfirmationTarget(
                stackID: stack.stackID,
                identity: stack.identity,
                state: state,
                action: action,
                registration: resolution.owners[stack.identity]
            )
        }

        // 停止コマンドの実行に使う設定は、同じ種類の対象スタックのうち起動順で最初のもの。
        var stopContexts: [ManagedStackType: ResolvedManagedStack] = [:]
        for stack in stacks where stopContexts[stack.type] == nil {
            switch stack.type.policy.conflictScope {
            case .allOfType:
                stopContexts[stack.type] = stack
            case .identityOnly:
                continue
            }
        }
        let targetIdentities = Set(stacks.map(\.identity))
        // 切替元の管理下スタックは通常の停止処理で止まる。確認を重ねて出さない。
        let stops = snapshot.observations.compactMap { observation -> ManagedStackExecutionPlan.Stop? in
            guard let context = stopContexts[observation.identity.type],
                  !targetIdentities.contains(observation.identity),
                  !skipped.contains(observation.identity) else {
                return nil
            }
            return ManagedStackExecutionPlan.Stop(identity: observation.identity, context: context)
        }
        let stopTargets = stops.map { stop -> ManagedStackConfirmationTarget in
            ManagedStackConfirmationTarget(
                stackID: nil,
                identity: stop.identity,
                state: snapshot.state(of: stop.identity),
                action: .stop,
                registration: resolution.owners[stop.identity]
            )
        }

        var fingerprints: [UUID: ManagedStackFingerprint] = [:]
        for stack in stacks {
            fingerprints[stack.stackID] = stack.fingerprint
        }
        return ManagedStackPlanDraft(
            plan: ManagedStackConfirmationPlan(
                environmentName: projectName,
                entries: targets + stopTargets,
                snapshot: snapshot,
                fingerprints: fingerprints
            ),
            targets: targets,
            stops: stops
        )
    }

    /// 切替元と一緒に停止される管理下スタックのID。
    private func managedIdentitiesStoppedWith(
        _ source: ProjectDefinition?
    ) async -> Set<ManagedStackIdentity> {
        guard let source else { return [] }
        let managed = await registry.managedStackIdentities()
        let sourceServiceIDs = Set(source.launchUnits.map(\.id))
        return Set(managed.filter { sourceServiceIDs.contains($0.key) }.values)
    }

    /// 観測できなかったスタックがあれば、変更操作の前に止める。
    ///
    /// `hasUnknown`は未観測の種類を数えないため、今回起動するスタックの種類（`required`）は
    /// 観測結果そのものがあることも要求する。結果が無い種類を`notRunning`扱いにして
    /// 確認なしの起動へ進まないためである。
    private func throwIfUnknown(
        _ snapshot: ManagedStackSnapshot,
        requiring required: Set<ManagedStackType>,
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) async throws {
        let unobserved = required
            .filter { !snapshot.hasResult(for: $0) }
            .sorted { $0.rawValue < $1.rawValue }
        let failedTypes = snapshot.typesWithUnknown
        guard !failedTypes.isEmpty || !unobserved.isEmpty else { return }

        let types = Set(failedTypes + unobserved).sorted { $0.rawValue < $1.rawValue }
        throw SwitchFailure(
            reason: .managedStackObservationFailed(
                types: types,
                details: snapshot.failureDetails
                    + unobserved.map(ManagedStackSnapshot.unobservedDetail)
            ),
            facts: await facts(source: source, target: target)
        )
    }

    /// 承認済みの停止対象を1件ずつ停止し、そのつど`notRunning`を確認する。
    /// 途中で失敗したら後続の停止と起動を中断し、停止済みのスタックは再起動しない。
    private func executeManagedStackStops(
        _ plan: ManagedStackExecutionPlan,
        source: ProjectDefinition?,
        target: ProjectDefinition,
        resolution: ManagedStackResolution,
        progress: @escaping ProgressSink
    ) async throws {
        var stopped: [String] = []
        var remaining = plan.stops
        let total = remaining.count
        while !remaining.isEmpty {
            let stop = remaining.removeFirst()
            let identity = stop.identity
            progress(
                .stopping(
                    service: "\(identity.type.displayName) \(identity)",
                    index: stopped.count + 1,
                    total: total
                )
            )
            do {
                try await registry.stopUnmanagedStack(identity, using: stop.context)
                stopped.append(identity.value)
            } catch {
                throw SwitchFailure(
                    reason: .managedStackStopFailed(
                        identity: identity,
                        reason: "\(error)",
                        stopped: stopped,
                        remaining: remaining.map(\.identity.value)
                    ),
                    facts: await facts(source: source, target: target)
                )
            }
        }

        // 停止が無くても、引き継ぐ直前に対象がまだ`running`かを確かめる。
        guard !plan.stops.isEmpty || plan.launches.contains(where: { $0.action == .adopt }) else { return }

        let latest = try await observeAndPlanManagedStacks(
            plan.launches.map(\.stack),
            source: source,
            target: target,
            resolution: resolution
        )
        let targetsAsExpected = zip(plan.launches, latest.targets).allSatisfy { launch, entry in
            let expected: ManagedStackState = launch.action == .adopt ? .running : .notRunning
            return entry.state == expected
        }
        guard targetsAsExpected, latest.stops.isEmpty else {
            // 停止後に予期しないスタックが現れた、または対象の状態が変わった。
            throw SwitchFailure(
                reason: .managedStackConfirmationRequired(plan: latest.plan),
                facts: await facts(source: source, target: target)
            )
        }
    }

    /// 計画に従って管理対象スタックを起動、または引き継ぐ。
    private func beginManagedStack(
        _ launch: ManagedStackExecutionPlan.Launch,
        in target: ProjectDefinition
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        switch launch.action {
        case .adopt:
            adoptedServiceIDs.insert(launch.stack.stackID)
            return try await registry.adoptManagedStack(
                launch.stack,
                in: target,
                relationship: .adopted,
                observation: ManagedStackObservation(
                    identity: launch.stack.identity,
                    state: .running
                )
            )
        case .start, .restart:
            // 停止を確認した以前の引き継ぎを、今回の起動の巻き戻し判定へ持ち越さない。
            clearState(of: launch.stack.stackID)
            return try await registry.startManagedStack(launch.stack, in: target)
        case .stop:
            throw RuntimeError.managedCommandInvalid(
                service: launch.stack.stackName,
                reason: "停止だけの計画から起動はできません。"
            )
        }
    }

    // MARK: - 保存済み手掛かりからの復元

    public enum ManagedRestoreOutcome: Equatable, Sendable {
        /// 実測と一致したため`restored`として管理下へ戻した。
        case restored(ManagedStackState)
        /// 対象スタックが`notRunning`と観測された。手掛かりは破棄してよい。
        case notRunning
        /// 再検証できないため、statusもstopも実行しなかった。手掛かりは残す。
        case skipped(reason: String)
    }

    /// アプリ起動時・フォアグラウンド復帰時の観測。
    /// 確認表示、引き継ぎ、停止は行わず、表示と管理下の実測値だけを更新する。
    @discardableResult
    public func observeManagedStacks(
        registeredProjects: [ProjectDefinition]
    ) async -> ManagedStackSnapshot {
        let resolution = resolveManagedStacks(
            registeredProjects: registeredProjects,
            source: nil,
            target: nil
        )
        await registry.setKnownStacks(resolution.stacks)
        return await refreshManagedObservations()
    }

    @discardableResult
    private func refreshManagedObservations() async -> ManagedStackSnapshot {
        let managed = await registry.managedStackIdentities()
        let snapshot = await registry.refreshManagedObservations()
        for (serviceID, identity) in managed where snapshot.observation(of: identity).state == .notRunning {
            clearState(of: serviceID)
        }
        return snapshot
    }

    /// 保存済み手掛かりを実測で再検証し、一致した場合だけ`restored`として管理下へ戻す。
    /// 保存値だけで稼働中へは戻さない。一致しなければコマンドを実行しない。
    public func restoreManagedStack(
        hint: ManagedStackHint,
        service: LaunchUnit,
        in project: ProjectDefinition,
        registeredProjects: [ProjectDefinition]
    ) async -> ManagedRestoreOutcome {
        guard !inFlight else {
            return .skipped(reason: "ほかの起動・停止・切替を実行中です。")
        }
        inFlight = true
        defer { inFlight = false }

        let hintType = hint.type
        guard hint.relationship != nil else {
            return .skipped(
                reason: "旧形式の手掛かりには\(hintType.identityLabel)と設定の記録がないため、状態確認コマンドを実行しません。"
            )
        }
        let resolution = resolveManagedStacks(
            registeredProjects: registeredProjects,
            source: nil,
            target: project
        )
        await registry.setKnownStacks(resolution.stacks)

        guard let stack = resolution.stacksByService[service.id] else {
            return .skipped(
                reason: "現在の設定から\(hintType.identityLabel)を解決できないため、状態確認コマンドを実行しません。"
            )
        }
        let mismatchReason =
            "保存時の設定ディレクトリ・起動コマンド・\(hintType.identityLabel)と一致しないため、状態確認コマンドを実行しません。"
        // 解決したスタックが、渡されたサービスと同じ開発環境・同じ設定から作られたものかを確かめる。
        // 手掛かりとの照合はサービスの設定で行うため、別の設定から解決した値でコマンドを実行しない。
        guard stack.type == hintType,
              stack.environmentID == project.id,
              stack.sourceConfiguration == service.managedStackDefinition?.configuration else {
            return .skipped(reason: mismatchReason)
        }
        // 保存時のIDと構成同一性が、現在の設定から解決した値と一致するときだけ実測する。
        guard hint.matches(stack) else {
            return .skipped(reason: mismatchReason)
        }

        let snapshot = await registry.observeManagedStacks()
        let observation = snapshot.observation(of: stack.identity)

        switch observation.state {
        case .notRunning:
            clearState(of: service.id)
            return .notRunning
        case .unknown:
            return .skipped(
                reason: observation.detail ?? "状態を確定できませんでした。"
            )
        case .running, .degraded:
            do {
                _ = try await registry.adoptManagedStack(
                    stack,
                    in: project,
                    relationship: .restored,
                    observation: observation
                )
            } catch {
                return .skipped(reason: "\(error)")
            }
            if observation.state == .running {
                startedServiceIDs.insert(service.id)
                failureReasons[service.id] = nil
            } else {
                // 停止導線は残す。起動済みにはしない。
                startedServiceIDs.remove(service.id)
                failureReasons[service.id] = observation.detail
                    ?? "\(stack.type.displayName)の必須コンテナが揃っていません。"
            }
            return .restored(observation.state)
        }
    }

    // MARK: - 起動前の検証

    /// MVP で実行できない設定を、停止を始める前に検出する。
    private func preflight(
        _ target: ProjectDefinition,
        source: ProjectDefinition?
    ) async -> SwitchFailure? {
        let units = target.enabledLaunchUnits
        guard !units.isEmpty else {
            return SwitchFailure(
                reason: .unsupportedConfiguration(
                    "プロジェクト「\(target.name)」で今回起動するサービスが1つもありません。起動対象を選んでください。"
                ),
                facts: await facts(source: source, target: target)
            )
        }

        // 1開発環境あたりのスタック数は種類ごとの上限まで。設定検証と同じ制約をここでも守る。
        // ここで数えるのは今回起動するスタック。
        let stacks = target.managedStacks
        for type in ManagedStackType.allCases {
            guard let limit = type.policy.maximumPerEnvironment else { continue }
            let stacksOfType = stacks.filter { $0.type == type }
            if stacksOfType.count > limit {
                return SwitchFailure(
                    reason: .unsupportedConfiguration(
                        ValidationError.managedStackLimitExceeded(
                            type: type,
                            limit: limit,
                            stacks: stacksOfType.map(\.name)
                        ).description
                    ),
                    facts: await facts(source: source, target: target)
                )
            }
        }

        for unit in units {
            let service: LaunchUnit
            switch unit {
            case let .stack(definition, workingDirectory):
                // 状態の観測と確認は`resolveManagedStackPlan`が行う。ここは設定の形式だけを見る。
                if let issue = definition.configuration
                    .structuralIssues(workingDirectory: workingDirectory)
                    .first {
                    return SwitchFailure(
                        reason: .unsupportedConfiguration(
                            RuntimeError.managedCommandInvalid(
                                service: definition.name,
                                reason: issue.failureReason
                            ).description
                        ),
                        facts: await facts(source: source, target: target)
                    )
                }
                continue
            case let .process(process):
                service = .process(process)
            }
            do {
                let process = try Self.process(service)
                if ProcessCommandClassification.supabaseStart(process.start) == .certain {
                    return SwitchFailure(reason: .unsupportedConfiguration("Supabase の起動は管理対象スタックとして登録してください。"), facts: await facts(source: source, target: target))
                }
                _ = try StartupObservationPolicy.spec(for: try Self.process(service))
            } catch {
                return SwitchFailure(
                    reason: .unsupportedConfiguration("\(error)"),
                    facts: await facts(source: source, target: target)
                )
            }
        }
        return nil
    }

    // MARK: - 停止フェーズ

    /// 単体再起動で、対象が実際に握っていたポートだけをゲートへ渡す。
    /// 再起動では直後に新しいプロセスを起こすため、観測不能なら停止前に中断する。
    private func stopForRestart(
        _ service: LaunchUnit,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink
    ) async throws -> [Int] {
        do {
            try await registry.refreshPorts(serviceID: service.id)
        } catch {
            throw SwitchFailure(
                reason: .portObservationFailed(
                    context: "サービス「\(service.name)」の実測ポート",
                    reason: "\(error)"
                ),
                facts: await facts(source: project, target: nil)
            )
        }

        guard let record = await registry.runtimeSnapshot(serviceID: service.id)?.observedPortRecord,
              let observed = record.observed else {
            throw SwitchFailure(
                reason: .portObservationFailed(
                    context: "サービス「\(service.name)」の実測ポート",
                    reason: "プロセスのlistenポートを取得できませんでした。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }

        progress(.stopping(service: service.name, index: 1, total: 1))
        try await stopOne(service, in: project)
        return Array(Set(observed)).sorted()
    }

    /// 1件だけを停止し、失敗時は既存の強制終了導線に必要な事実を返す。
    private func stopOne(
        _ service: LaunchUnit,
        in project: ProjectDefinition
    ) async throws {
        let outcome: ServiceStopOutcome
        do {
            outcome = try await registry.stop(service: service, grace: options.stopGrace)
        } catch {
            if await registry.occupiedProcessGroup(serviceID: service.id) == nil {
                clearState(of: service.id)
                return
            }
            let detail = StopFailureDetail(
                serviceID: service.id,
                serviceName: service.name,
                processGroupID: await registry.occupiedProcessGroup(serviceID: service.id),
                reason: "\(error)"
            )
            failureReasons[service.id] = "\(error)"
            throw SwitchFailure(
                reason: .stopFailed(services: [detail]),
                facts: await facts(source: project, target: nil)
            )
        }

        switch outcome {
        case .stopped:
            clearState(of: service.id)
        case let .residual(processGroupID, reason):
            residualGroups[service.id] = processGroupID
            failureReasons[service.id] = reason
            startedServiceIDs.remove(service.id)
            throw SwitchFailure(
                reason: .stopFailed(services: [
                    StopFailureDetail(
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: processGroupID,
                        reason: reason
                    ),
                ]),
                facts: await facts(source: project, target: nil)
            )
        case let .ownershipLost(reason):
            failureReasons[service.id] = reason
            startedServiceIDs.remove(service.id)
            throw SwitchFailure(
                reason: .stopFailed(services: [
                    StopFailureDetail(
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: nil,
                        reason: reason
                    ),
                ]),
                facts: await facts(source: project, target: nil)
            )
        }
    }

    /// 停止対象は、設定上ポートを持つサービスではなく、実際に起動または引き継いだサービスから決める。
    /// 返すのはゲート1で解放を確認すべき実測ポート。
    private func stopPhase(
        _ source: ProjectDefinition,
        target: ProjectDefinition?,
        excluding preservedServiceIDs: Set<UUID> = [],
        progress: @escaping ProgressSink
    ) async throws -> [Int] {
        let occupying = await registry.occupyingServiceIDs(projectID: source.id)
        let toStop = source.shutdownUnits.filter {
            occupying.contains($0.id) && !preservedServiceIDs.contains($0.id)
        }

        // 停止前にポートを実測し直す。定期ポーリングの間隔ぶん古い値でゲートを判定しない。
        for service in toStop {
            do {
                try await registry.refreshPorts(serviceID: service.id)
            } catch {
                // 切替では最新観測だけをゲート1の根拠にする。古い実測値への退避はしない。
                // 単独停止は次のプロジェクトを起動しないため継続し、UIへ unavailable を残す。
                if target != nil {
                    throw SwitchFailure(
                        reason: .portObservationFailed(
                            context: "サービス「\(service.name)」の実測ポート",
                            reason: "\(error)"
                        ),
                        facts: await facts(source: source, target: target)
                    )
                }
            }
        }

        var measuredPorts: [Int] = []
        for service in toStop {
            if let record = await registry.runtimeSnapshot(serviceID: service.id)?.observedPortRecord,
               let ports = record.observed {
                measuredPorts.append(contentsOf: ports)
            }
        }
        let portsToRelease = Array(Set(measuredPorts)).sorted()

        var stopFailures: [StopFailureDetail] = []

        for (index, service) in toStop.enumerated() {
            progress(.stopping(service: service.name, index: index + 1, total: toStop.count))
            let outcome: ServiceStopOutcome
            do {
                outcome = try await registry.stop(service: service, grace: options.stopGrace)
            } catch {
                // 停止操作の前にプロセスが消えていることがある。実測して確かめる。
                if await registry.isOccupyingResources(serviceID: service.id) == false {
                    clearState(of: service.id)
                    continue
                }
                stopFailures.append(
                    StopFailureDetail(
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: await registry.occupiedProcessGroup(serviceID: service.id),
                        reason: "\(error)"
                    )
                )
                failureReasons[service.id] = "\(error)"
                continue
            }

            switch outcome {
            case let .stopped(_, warning):
                clearState(of: service.id)
                if let warning { failureReasons[service.id] = warning }
            case let .residual(processGroupID, reason):
                stopFailures.append(
                    StopFailureDetail(
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: processGroupID,
                        reason: reason
                    )
                )
                residualGroups[service.id] = processGroupID
                failureReasons[service.id] = reason
                startedServiceIDs.remove(service.id)
            case let .ownershipLost(reason):
                stopFailures.append(
                    StopFailureDetail(
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: nil,
                        reason: reason
                    )
                )
                failureReasons[service.id] = reason
                startedServiceIDs.remove(service.id)
            }
        }

        guard stopFailures.isEmpty else {
            throw SwitchFailure(
                reason: .stopFailed(services: stopFailures),
                facts: await facts(source: source, target: target)
            )
        }

        // 明示的な停止が完了したら、このプロジェクトのサービスはすべて停止中にする。
        // 以前の起動失敗を残したままにすると、止めたはずのプロジェクトが
        // 「一部停止」「失敗」と表示され続け、稼働中の一種として扱われてしまう。
        await clearProjectStateIfFullyStopped(source)

        return portsToRelease
    }

    /// プロジェクトの資源がすべて解放されていることを実測してから、今回の結果を消す。
    /// 記録だけを消して実際には動いている、という状態を作らないため、確認してから消す。
    private func clearProjectStateIfFullyStopped(_ project: ProjectDefinition) async {
        for service in project.launchUnits {
            if await registry.isOccupyingResources(serviceID: service.id) { return }
            if await registry.occupiedProcessGroup(serviceID: service.id) != nil { return }
        }
        for service in project.launchUnits {
            clearState(of: service.id)
        }
    }

    // MARK: - ゲート（停止元の実測ポート解放）

    private func releaseGate(
        ports: [Int],
        source: ProjectDefinition,
        target: ProjectDefinition?,
        progress: @escaping ProgressSink
    ) async throws {
        guard !ports.isEmpty else {
            progress(.verifyingRelease(released: 0, total: 0))
            return
        }

        let deadline = ContinuousClock.now + options.releaseTimeout
        var remaining: [ObservedPortHolder] = []

        while true {
            do {
                remaining = try await portHolderProbe(ports)
            } catch {
                throw SwitchFailure(
                    reason: .portObservationFailed(
                        context: "停止元のポート解放確認",
                        reason: "\(error)"
                    ),
                    facts: await facts(source: source, target: target)
                )
            }

            let releasedCount = ports.count - Set(remaining.map(\.port)).count
            progress(.verifyingRelease(released: releasedCount, total: ports.count))

            if remaining.isEmpty { return }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: options.gatePollInterval)
        }

        throw SwitchFailure(
            reason: .portsNotReleased(holders: await resolve(remaining)),
            facts: await facts(source: source, target: target)
        )
    }

    // MARK: - 起動フェーズ

    /// 設定順にすべてのサービスを起動する。
    ///
    /// 同じ設定ポートを持つサービスがあっても、後続をスキップしたり別のポートを割り当てたりしない。
    /// ポートを取れるかは OS が決める（先に bind したプロセスが取る）。
    /// 取れずに終了したサービスは、通常の起動失敗として `failurePolicy` に従って扱う。
    ///
    /// 戻り値は `failurePolicy: continue` で起動できなかったサービス名（一部停止の内訳）。
    private func startPhase(
        _ target: ProjectDefinition,
        source: ProjectDefinition?,
        stackPlan: ManagedStackExecutionPlan?,
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws -> [String] {
        let units = target.enabledLaunchUnits
        var startedInThisRun: [LaunchUnit] = []
        var degraded: [String] = []

        for (index, unit) in units.enumerated() {
            let service = unit
            progress(.starting(service: unit.name, index: index + 1, total: units.count))
            // 同じ設定で再試行したとき、前回の失敗理由を今回の理由へ連結しない。
            failureReasons[unit.id] = nil

            let spec: StartupObservationSpec?
            switch unit {
            case .stack:
                spec = nil
            case .process:
                do {
                    spec = try StartupObservationPolicy.spec(
                        for: try Self.process(service),
                        observationWindow: options.startupObservationWindow,
                        pollInterval: options.startupPollInterval
                    )
                } catch {
                    // preflight で弾いているはずだが、ここでも既定へ倒さない。
                    try await failStart(
                        service: service,
                        reason: "\(error)",
                        target: target,
                        source: source,
                        startedInThisRun: startedInThisRun,
                        degraded: &degraded,
                        progress: progress
                    )
                    continue
                }
            }

            do {
                // 前回停止時のログは原因調査のため残し、新しい起動を試す時点で区切る。
                events(unit.id, .logSessionStarted)
                let observation = ServiceObservation()
                let stream: AsyncStream<ServiceSupervisor.Event>
                switch unit {
                case let .stack(definition, _):
                    guard let launch = stackPlan?.launch(of: definition.id) else {
                        throw RuntimeError.managedCommandInvalid(
                            service: definition.name,
                            reason: "既存スタックの実測結果がないため、\(definition.type.displayName)を起動しません。"
                        )
                    }
                    stream = try await beginManagedStack(launch, in: target)
                case let .process(process):
                    stream = try await registry.start(service: process, in: target)
                }
                observations[unit.id] = observation
                consumers[unit.id]?.cancel()
                consumers[unit.id] = Task {
                    for await event in stream {
                        // 先に観測へ記録してからUIへ流す。逆にすると、UI が終了を受けて
                        // 状態を問い合わせた時点でこちらがまだ終了を知らないことがある。
                        let observedEvent = await observation.record(event)
                        events(unit.id, observedEvent)
                    }
                }
                // 引き継いだスタックは今回起動していない。巻き戻しの対象へ入れない。
                if !adoptedServiceIDs.contains(unit.id) {
                    startedInThisRun.append(service)
                }
                failureReasons[unit.id] = nil
                residualGroups[unit.id] = nil
            } catch {
                try await handleStartFailure(
                    error,
                    service: service,
                    target: target,
                    source: source,
                    startedInThisRun: startedInThisRun,
                    degraded: &degraded,
                    progress: progress,
                    events: events
                )
                continue
            }

            // スタックは起動または引き継ぎの時点で`running`を確認済み。
            // 終了済みの開始コマンドを通常の初期観測へ渡してはいけない。
            if case .stack = unit {
                startedServiceIDs.insert(unit.id)
                failureReasons[unit.id] = nil
                continue
            }

            progress(.observingStartup(service: service.name))
            guard let spec else {
                preconditionFailure("通常プロセスの起動確認条件がありません。")
            }
            let result = await awaitStartupObservation(service: service, spec: spec)
            switch result {
            case .passed:
                startedServiceIDs.insert(service.id)
                failureReasons[service.id] = nil
            case let .failed(reason):
                // 起動できなかったサービスは、握った資源を残さないよう停止する。
                await stopAfterFailedStart(service)
                startedInThisRun.removeAll { $0.id == service.id }
                try await failStart(
                    service: service,
                    reason: reason,
                    target: target,
                    source: source,
                    startedInThisRun: startedInThisRun,
                    degraded: &degraded,
                    progress: progress
                )
            }
        }

        return degraded
    }

    private static func process(_ unit: LaunchUnit) throws -> ServiceDefinition {
        guard case let .process(service) = unit else {
            throw RuntimeError.managedCommandInvalid(service: unit.name, reason: "スタックは通常プロセスとして操作できません。")
        }
        return service
    }

    private func handleStartFailure(
        _ error: Error,
        service: LaunchUnit,
        target: ProjectDefinition,
        source: ProjectDefinition?,
        startedInThisRun: [LaunchUnit],
        degraded: inout [String],
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws {
        let startReason = "\(error)"
        if isManagedStartOwnershipUnconfirmed(error) {
            failureReasons[service.id] = startReason
            startedServiceIDs.remove(service.id)
            await rollback(startedInThisRun, progress: progress)
            throw SwitchFailure(
                reason: .startFailed(service: service.name, reason: startReason),
                facts: await facts(source: source, target: target)
            )
        }
        if await registry.isOccupyingResources(serviceID: service.id) {
            await stopAfterFailedStart(service)
        }
        let reason = failureReasons[service.id].map {
            startReason + "\n" + $0
        } ?? startReason

        // 補償停止できずに資源が残るなら、`continue`でも後続を起動しない。
        // 残存を抱えたまま次のサービスを起動すると、止め方の分からない状態が積み上がる。
        if await registry.isOccupyingResources(serviceID: service.id) {
            failureReasons[service.id] = reason
            startedServiceIDs.remove(service.id)
            residualManagedServiceIDs.insert(service.id)
            await rollback(startedInThisRun, progress: progress)
            throw SwitchFailure(
                reason: .startFailed(service: service.name, reason: reason),
                facts: await facts(source: source, target: target)
            )
        }

        try await failStart(
            service: service,
            reason: reason,
            target: target,
            source: source,
            startedInThisRun: startedInThisRun,
            degraded: &degraded,
            progress: progress
        )
    }

    private func isManagedStartOwnershipUnconfirmed(_ error: any Error) -> Bool {
        guard let runtimeError = error as? RuntimeError else { return false }
        if case .managedStartOwnershipUnconfirmed = runtimeError { return true }
        return false
    }

    /// 1件の起動失敗では、操作前から動いていた他サービスを巻き戻さない。
    private func serviceStartFailure(
        _ error: Error,
        service: LaunchUnit,
        project: ProjectDefinition
    ) async -> SwitchFailure {
        let startReason = "\(error)"
        if await registry.occupiedProcessGroup(serviceID: service.id) != nil {
            await stopAfterFailedStart(service)
        }
        let reason = failureReasons[service.id].map {
            startReason + "\n" + $0
        } ?? startReason
        failureReasons[service.id] = reason
        startedServiceIDs.remove(service.id)
        if let processGroupID = await registry.occupiedProcessGroup(serviceID: service.id) {
            residualGroups[service.id] = processGroupID
        }
        return SwitchFailure(
            reason: .startFailed(service: service.name, reason: reason),
            facts: await facts(source: nil, target: project)
        )
    }

    /// 今回このrunで起動したものだけを、起動順の逆に停止する。
    /// 引き継いだ管理対象スタックは巻き戻さず、残存ありとして停止導線を残す。
    private func rollback(
        _ startedInThisRun: [LaunchUnit],
        progress: @escaping ProgressSink
    ) async {
        for started in startedInThisRun.reversed() {
            progress(.rollingBack(service: started.name))
            await stopAfterFailedStart(started)
        }
        for serviceID in adoptedServiceIDs {
            if await registry.isOccupyingResources(serviceID: serviceID) {
                residualManagedServiceIDs.insert(serviceID)
            }
        }
    }

    /// `block` なら今回起動したサービスを安全に停止して中断、`continue` なら一部停止として続行。
    private func failStart(
        service: LaunchUnit,
        reason: String,
        target: ProjectDefinition,
        source: ProjectDefinition?,
        startedInThisRun: [LaunchUnit],
        degraded: inout [String],
        progress: @escaping ProgressSink
    ) async throws {
        failureReasons[service.id] = reason
        startedServiceIDs.remove(service.id)

        switch service.failurePolicy {
        case .continue:
            degraded.append(service.name)
        case .block:
            // 以前から動いていたプロセスと、引き継いだスタックまで巻き込まない。
            await rollback(startedInThisRun, progress: progress)
            throw SwitchFailure(
                reason: .startFailed(service: service.name, reason: reason),
                facts: await facts(source: source, target: target)
            )
        }
    }

    private func stopAfterFailedStart(_ service: LaunchUnit) async {
        guard await registry.isOccupyingResources(serviceID: service.id) else {
            startedServiceIDs.remove(service.id)
            return
        }
        do {
            let outcome = try await registry.stop(service: service, grace: options.stopGrace)
            switch outcome {
            case .stopped:
                startedServiceIDs.remove(service.id)
                residualGroups[service.id] = nil
            case let .residual(processGroupID, reason):
                residualGroups[service.id] = processGroupID
                let existing = failureReasons[service.id].map { $0 + "\n" } ?? ""
                failureReasons[service.id] = existing + reason
                startedServiceIDs.remove(service.id)
            case let .ownershipLost(reason):
                failureReasons[service.id] = reason
                startedServiceIDs.remove(service.id)
            }
        } catch {
            startedServiceIDs.remove(service.id)
            let existing = failureReasons[service.id].map { $0 + "\n" } ?? ""
            failureReasons[service.id] = existing + "補償停止に失敗しました。\n\(error)"
            if let processGroupID = await registry.occupiedProcessGroup(serviceID: service.id) {
                residualGroups[service.id] = processGroupID
            }
        }
    }

    // MARK: - 起動確認

    private enum StartupResult {
        case passed
        case failed(reason: String)
    }

    /// 起動成功の判定。
    ///
    /// 設定ポートへ HTTP は投げない。同じポートを先に取った別サービスの応答を
    /// 自分の応答と誤認するため、判定材料はプロセスの生存だけにする。
    /// 初期観測期間に終了せず、観測終了時点でも管理下にあれば起動成功とする。
    private func awaitStartupObservation(
        service: LaunchUnit,
        spec: StartupObservationSpec
    ) async -> StartupResult {
        let observation = observations[service.id]

        let deadline = ContinuousClock.now + spec.observationWindow
        while ContinuousClock.now < deadline {
            if let exit = await observation?.exit {
                return .failed(reason: await exitReason(exit, observation: observation))
            }
            try? await Task.sleep(for: spec.pollInterval)
        }
        if let exit = await observation?.exit {
            return .failed(reason: await exitReason(exit, observation: observation))
        }
        guard await registry.isRunning(serviceID: service.id) else {
            return .failed(reason: "起動直後にプロセスが終了しました。")
        }
        if let observation, !(await observation.confirmStartup()) {
            guard let exit = await observation.exit else {
                return .failed(reason: "起動直後のプロセス状態を確定できませんでした。")
            }
            return .failed(reason: await exitReason(exit, observation: observation))
        }
        return .passed
    }

    private func exitReason(
        _ exit: ServiceObservation.ExitRecord,
        observation: ServiceObservation?
    ) async -> String {
        let tail = await observation?.tailText ?? ""
        let base = "起動直後に終了しました（\(exit.status.description)）。"
        return tail.isEmpty ? base : base + "\n直近のログ:\n" + tail
    }

    // MARK: - 引き継ぎ

    /// 実測で照合済みの候補を管理下へ置く。新しいプロセスは起動しない。
    /// 引き継いだ後も初期観測を行い、直後に消えるプロセスを起動済みと扱わない。
    public func adopt(
        _ candidate: HandoffCandidate,
        service: LaunchUnit,
        in project: ProjectDefinition,
        events: @escaping EventSink = { _, _ in }
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        try await registry.adopt(candidate: candidate, service: try Self.process(service), in: project)
        clearState(of: service.id)
        events(service.id, .logSessionStarted)
        do {
            try await registry.resumeAdoptedLogs(serviceID: service.id) { event in
                events(service.id, event)
            }
        } catch {
            // 読み取り失敗でも引き継ぎ済みの管理関係は保ち、利用者が停止できるようにする。
            events(service.id, .logUnavailable("引き継いだプロセスのログを取得できません。\n\(error)"))
        }

        let spec: StartupObservationSpec
        do {
            spec = try StartupObservationPolicy.spec(
                for: try Self.process(service),
                observationWindow: options.startupObservationWindow,
                pollInterval: options.startupPollInterval
            )
        } catch {
            failureReasons[service.id] = "\(error)"
            return
        }

        switch await awaitStartupObservation(service: service, spec: spec) {
        case .passed:
            startedServiceIDs.insert(service.id)
        case let .failed(reason):
            // 利用者が明示的に「引き継ぐ」を選んだプロセスなので、勝手に停止しない。
            // 起動済みとも扱わず、確認できなかった事実を残す。
            failureReasons[service.id] = reason
        }
    }

    /// 引き継がずに停止する。利用者が「停止する」を選んだ場合にだけ呼ぶ。
    public func stopAdopted(
        _ candidate: HandoffCandidate,
        service: LaunchUnit,
        in project: ProjectDefinition
    ) async throws -> ServiceStopOutcome {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        try await registry.adopt(candidate: candidate, service: try Self.process(service), in: project)
        return try await stopRegistered(service: service)
    }

    /// 引き継げないが停止はできるプロセスを停止する。
    ///
    /// 根拠ごとに管理方法が違う。本体が一致しているなら開始時刻で、
    /// 本体が居ないならプロセスグループの同定条件で、送信直前に再検証する。
    public func stopWithoutAdopting(
        _ finding: StoppableProcessFinding,
        service: LaunchUnit,
        in project: ProjectDefinition
    ) async throws -> ServiceStopOutcome {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        switch finding.evidence {
        case let .matchedLeader(identity):
            try await registry.adopt(
                identity: identity,
                processGroupID: finding.hint.processGroupID,
                observedPorts: [],
                evidence: finding.groupEvidence,
                service: try Self.process(service),
                in: project
            )
        case .verifiedGroup:
            // 実測し直した証拠で登録する。保存時の古い錨を使うと、
            // 記録後に生まれた子孫を同定できない。
            try await registry.registerResidualGroup(
                hint: finding.hint.updatingGroupEvidence(finding.groupEvidence),
                service: try Self.process(service),
                in: project
            )
        }
        try await registry.registerStopCommandRole(finding.hint)
        return try await stopRegistered(service: service)
    }

    private func stopRegistered(service: LaunchUnit) async throws -> ServiceStopOutcome {
        do {
            let outcome = try await registry.stop(service: service, grace: options.stopGrace)
            if case let .residual(processGroupID, reason) = outcome {
                residualGroups[service.id] = processGroupID
                failureReasons[service.id] = reason
            } else if case let .ownershipLost(reason) = outcome {
                failureReasons[service.id] = reason
                residualGroups[service.id] = nil
            } else {
                clearState(of: service.id)
            }
            return outcome
        } catch {
            failureReasons[service.id] = "\(error)"
            throw error
        }
    }

    // MARK: - 強制終了

    /// 通常終了で止まらなかったサービスを強制終了する。
    ///
    /// 利用者が対象を確認して明示的に選んだ場合にだけ呼ぶこと。
    /// 呼び出し側は事前確認を必ず挟む（docs/SPEC.md 7、12）。
    public func forceStop(
        serviceIDs: [UUID],
        in project: ProjectDefinition
    ) async throws -> [UUID: ServiceStopOutcome] {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        var outcomes: [UUID: ServiceStopOutcome] = [:]
        for serviceID in serviceIDs {
            guard let service = project.entry(id: serviceID) else { continue }
            guard await registry.isOccupyingResources(serviceID: serviceID) else {
                // 送信前に消えていた。止まったこと自体は実測どおりなので成功として扱う。
                clearState(of: serviceID)
                outcomes[serviceID] = .stopped(nil)
                continue
            }
            let outcome = try await registry.forceStop(
                service: service,
                grace: options.stopGrace
            )
            switch outcome {
            case .stopped:
                clearState(of: serviceID)
            case let .residual(processGroupID, reason):
                residualGroups[serviceID] = processGroupID
                failureReasons[serviceID] = reason
            case let .ownershipLost(reason):
                residualGroups[serviceID] = nil
                failureReasons[serviceID] = reason
            }
            outcomes[serviceID] = outcome
        }

        // 強制終了で資源が解放されたなら、それ以前の失敗も含めて停止中に戻す。
        await clearProjectStateIfFullyStopped(project)
        return outcomes
    }

    // MARK: - 状態

    public func servicePhase(
        _ service: LaunchUnit,
        in project: ProjectDefinition
    ) async -> ServicePhase {
        if residualGroups[service.id] != nil { return .residual }
        if let reason = restartRecoveries[service.id]?.failureReason {
            return .failed(reason: reason)
        }
        // 巻き戻し後も残った引き継ぎ分は「残存あり」。停止導線を画面から消さない。
        if residualManagedServiceIDs.contains(service.id),
           await registry.isOccupyingResources(serviceID: service.id) {
            return .residual
        }
        if let reason = failureReasons[service.id] {
            // 失敗理由があっても停止対象をRegistryが保持しているなら、単なる失敗ではない。
            // 残存扱いにしないとプロジェクトが非稼働になり、停止の導線が画面から消える。
            if await registry.isOccupyingResources(serviceID: service.id) {
                return .residual
            }
            return .failed(reason: reason)
        }
        if await registry.isRunning(serviceID: service.id) {
            return startedServiceIDs.contains(service.id) ? .healthy : .running
        }
        // 管理対象スタックのdegraded / unknownは、プロセスのPGIDを持たない。
        // 管理関係と資源占有が残る限り、停止中へ倒さず停止導線を残す。
        if await registry.isOccupyingResources(serviceID: service.id) {
            return .residual
        }
        // 起動したプロセスは終了したのに、孫がプロセスグループに残っていることがある。
        // これを「失敗」や「停止中」と表示すると、資源を握ったままなのに
        // 停止の導線が出ず、画面から復旧できなくなる。
        if await registry.occupiedProcessGroup(serviceID: service.id) != nil {
            return .residual
        }
        // 停止操作なしに終了していたら「停止中」で塗りつぶさない。
        // 終了コード0でも、頼んでいない終了はサービスの成功ではない。
        // 終了イベントのconsumerが未実行でも、Supervisorが持つ実測結果を使う。
        // 明示停止後はclearStateが観測を消すので、古い終了結果を再表示しない。
        if observations[service.id] != nil,
           let exit = await registry.observedExit(serviceID: service.id),
           !exit.requestedByUser {
            return .failed(reason: "停止操作なしに終了しました（\(exit.status.description)）")
        }
        // 引き継いだ通常プロセスには終了イベントの観測記録がない。
        // 初期観測を通過した本体も残存グループも確認できなければ、対象外へ戻さず失敗にする。
        // 明示停止ではclearStateが起動済みの記録を消すため、この判定には入らない。
        if service.managedStackDefinition == nil,
           startedServiceIDs.contains(service.id),
           observations[service.id] == nil {
            return .failed(reason: "引き継いだプロセスが停止操作なしに終了しました（終了コードは取得できません）")
        }
        if !project.isEnabledNow(service.id) { return .excluded }
        return .stopped
    }

    public func projectFact(_ project: ProjectDefinition) async -> ProjectFact {
        var services: [ServiceFact] = []
        for service in project.launchUnits {
            let phase = await servicePhase(service, in: project)
            let ports = await registry.runtimeSnapshot(serviceID: service.id)?
                .observedPortRecord ?? .observed([])
            services.append(
                ServiceFact(
                    serviceID: service.id,
                    name: service.name,
                    phase: phase,
                    observedPorts: ports
                )
            )
        }
        return ProjectFact(
            projectID: project.id,
            projectName: project.name,
            phase: projectPhase(project, services: services),
            services: services,
            warnings: await registry.stopWarnings(projectID: project.id)
        )
    }

    /// 実測で「対象外」のものだけを除く。今回追加起動したプロセスの失敗も集計する。
    private func projectPhase(
        _ project: ProjectDefinition,
        services: [ServiceFact]
    ) -> ProjectPhase {
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) })

        if services.contains(where: { $0.phase == .residual }) { return .residual }

        let servicesInThisRun = project.launchUnits.map { service -> (definition: LaunchUnit, phase: ServicePhase) in
            guard let fact = byID[service.id] else {
                preconditionFailure("プロジェクトの状態判定に必要なサービスの観測結果がありません。")
            }
            return (definition: service, phase: fact.phase)
        }.filter { $0.phase != .excluded }
        guard !servicesInThisRun.isEmpty else { return .stopped }

        if servicesInThisRun.allSatisfy({ $0.phase == .healthy }) { return .running }
        if servicesInThisRun.allSatisfy({ $0.phase == .stopped }) { return .stopped }
        if servicesInThisRun.contains(where: { $0.phase == .starting || $0.phase == .running }) {
            return .starting
        }

        // 稼働できていないサービスのうち、1つでも block があればプロジェクトの失敗。
        // continue だけなら一部停止（稼働中の一種）。
        let unavailable = servicesInThisRun.filter { $0.phase != .healthy }
        if let blocking = unavailable.first(where: { $0.definition.failurePolicy == .block }) {
            let reason: String
            if case let .failed(detail) = blocking.phase {
                reason = detail
            } else {
                reason = "サービス「\(blocking.definition.name)」が起動できていません。"
            }
            return .failed(reason: reason)
        }
        return .degraded(stoppedServices: unavailable.map { $0.definition.name })
    }

    private func facts(
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) async -> CurrentStateFacts {
        var sourceFact: ProjectFact?
        if let source { sourceFact = await projectFact(source) }
        var targetFact: ProjectFact?
        if let target { targetFact = await projectFact(target) }
        return CurrentStateFacts(source: sourceFact, target: targetFact)
    }

    public func currentFacts(
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) async -> CurrentStateFacts {
        await facts(source: source, target: target)
    }

    // MARK: - 補助

    private func throwIfCancelled(
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) async throws {
        guard cancelRequested else { return }
        throw SwitchFailure(
            reason: .cancelled,
            facts: await facts(source: source, target: target)
        )
    }

    /// そのサービスの「今回の結果」をすべて消す。
    ///
    /// 観測記録も一緒に消す。停止操作なしの終了を`servicePhase`が失敗として読むため、
    /// 残したままだと明示的に停止したあとも失敗のままになる。
    private func clearState(of serviceID: UUID) {
        startedServiceIDs.remove(serviceID)
        failureReasons[serviceID] = nil
        residualGroups[serviceID] = nil
        restartRecoveries[serviceID] = nil
        observations[serviceID] = nil
        adoptedServiceIDs.remove(serviceID)
        residualManagedServiceIDs.remove(serviceID)
    }

    /// 外部プロセスを自動終了しないため、所有区分を実測と自分の記録から決める。
    private func resolve(_ holders: [ObservedPortHolder]) async -> [ResolvedPortHolder] {
        var resolved: [ResolvedPortHolder] = []
        for holder in holders {
            let ownership: PortOwnership
            if let owned = await registry.ownership(ofPID: holder.pid) {
                ownership = .ownedByUs(serviceID: owned.serviceID, serviceName: owned.serviceName)
            } else if let loginName = holder.loginName,
                      loginName == currentUserName,
                      loginName != "root" {
                ownership = .external
            } else {
                // 所有者を確認できない、または別利用者・システム管理下。終了操作は出さない。
                ownership = .systemOwned
            }
            resolved.append(
                ResolvedPortHolder(
                    port: holder.port,
                    pid: holder.pid,
                    command: holder.command,
                    ownership: ownership
                )
            )
        }
        return resolved.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }
}
