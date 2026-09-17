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
    /// 失敗シートに出す行数（DESIGN.md）。stdout と stderr を時系列のまま保つ。
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
/// 起動フェーズへ入れない構造にしてある（DESIGN.md I-3）。判定のソースは実測だけで、
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
    /// 今回引き継いだSupabase。今回起動した分と違い、巻き戻しの対象にしない。
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

    /// 起動フェーズへ入る前だけ受け付ける（DESIGN.md I-4）。
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
    /// `registeredProjects`は`project_id`の一意性確認と、既存スタックの登録有無の表示に使う。
    /// `supabaseApproval`は利用者が確認シートで承認した内容。承認前は既存スタックを変更しない。
    public func start(
        _ project: ProjectDefinition,
        registeredProjects: [ProjectDefinition] = [],
        supabaseApproval: SupabaseApproval? = nil,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: nil,
            starting: project,
            registeredProjects: registeredProjects,
            supabaseApproval: supabaseApproval,
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
            supabaseApproval: nil,
            progress: progress,
            events: events
        )
    }

    /// 切替。停止 → ポート解放の確認 → 起動の順を崩さない。
    public func switchProject(
        from source: ProjectDefinition,
        to target: ProjectDefinition,
        registeredProjects: [ProjectDefinition] = [],
        supabaseApproval: SupabaseApproval? = nil,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: source,
            starting: target,
            registeredProjects: registeredProjects,
            supabaseApproval: supabaseApproval,
            progress: progress,
            events: events
        )
    }

    /// 起動済みプロジェクトへ通常プロセス1件を追加する。保存済みの起動対象は変更しない。
    @discardableResult
    public func startService(
        _ service: ServiceDefinition,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> ProjectFact {
        try await runServiceOperation(service, in: project, restarting: false, progress: progress, events: events)
    }

    /// 起動済みプロジェクトの通常プロセス1件だけを再起動する。
    ///
    /// プロジェクト全体の起動順を再実行せず、対象の停止、実測ポートの解放確認、
    /// 起動直後の観測だけを同じ排他境界で行う。Supabaseは専用lifecycleを持つため対象外。
    @discardableResult
    public func restart(
        _ service: ServiceDefinition,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> ProjectFact {
        try await runServiceOperation(service, in: project, restarting: true, progress: progress, events: events)
    }

    /// 追加起動と再起動で、初期観測・ログ・失敗時の停止を共有する。
    private func runServiceOperation(
        _ service: ServiceDefinition,
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

        guard project.service(id: service.id) == service else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "サービス「\(service.name)」の設定がプロジェクト「\(project.name)」の登録内容と一致しません。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        guard service.kind != .supabase else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "Supabaseは通常プロセスと停止・状態確認の方法が異なるため、単体の起動・再起動はできません。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        guard service.usesProcessGroupStop else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    RuntimeError.stopCommandUnsupported(service: service.name).description
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
                for: service,
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
        _ service: ServiceDefinition,
        in project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in }
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        guard project.service(id: service.id) != nil else {
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
    /// 引き継いだSupabaseと操作前から管理していた対象は、明示停止のために残す。
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
            let relationship = await registry.managedRelationship(serviceID: serviceID)
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
        supabaseApproval: SupabaseApproval?,
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

        // 登録済みSupabaseの`project_id`を毎回解決し直す。観測の基準もここで入れ替える。
        let supabaseResolution = resolveSupabaseConfigurations(
            registeredProjects: registeredProjects,
            source: source,
            target: target
        )
        await registry.setKnownSupabaseConfigurations(supabaseResolution.configurations)
        // 起動・停止・切替の直前に実測し直す。保存済みの表示値のまま停止判断をしない。
        await refreshManagedObservations()
        // 解決できない、または重複する`project_id`があれば新しい起動・切替はしない。
        // 単独停止は復旧手段なので、この理由では止めない。
        if target != nil, !supabaseResolution.errors.isEmpty {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "Supabaseの`project_id`を確認できません。\n"
                        + supabaseResolution.errors.joined(separator: "\n")
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
        var supabasePlan: SupabaseExecutionPlan?
        if let target {
            supabasePlan = try await resolveSupabasePlan(
                target: target,
                source: source,
                resolution: supabaseResolution,
                approval: supabaseApproval
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
        if let supabasePlan {
            try await executeSupabaseStops(
                supabasePlan,
                source: source,
                target: target,
                resolution: supabaseResolution,
                progress: progress
            )
        }
        let degraded = try await startPhase(
            target,
            source: source,
            supabasePlan: supabasePlan,
            progress: progress,
            events: events
        )

        progress(.completed)
        return SwitchOutcome(
            facts: await facts(source: source, target: target),
            degradedServices: degraded
        )
    }

    // MARK: - Supabaseスタック

    /// 今回の起動対象に対して確定した処理内容。
    /// 確認が必要な場合は、この値を作る前に`SwitchFailure`で中断している。
    private struct SupabaseExecutionPlan {
        let service: ServiceDefinition
        let configuration: SupabaseServiceConfiguration
        let projectID: SupabaseProjectID
        /// `adopt`は`supabase start`を実行しない。`restart`は対象を停止してから起動する。
        let action: SupabaseConfirmationTarget.Action
        /// 起動前に停止する`project_id`。`restart`では対象自身も含む。
        let stopProjectIDs: [SupabaseProjectID]
    }

    /// 登録済みSupabaseの設定解決結果。
    private struct SupabaseConfigurationResolution {
        var configurations: [SupabaseProjectID: SupabaseServiceConfiguration] = [:]
        var projectIDsByService: [UUID: SupabaseProjectID] = [:]
        var owners: [SupabaseProjectID: SupabaseConfirmationTarget.Registration] = [:]
        var errors: [String] = []
    }

    /// 全登録済みSupabaseの`project_id`を設定ファイルから解決し、重複を検出する。
    /// 解決できないものは既定値で補わず、理由を残す。
    private func resolveSupabaseConfigurations(
        registeredProjects: [ProjectDefinition],
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) -> SupabaseConfigurationResolution {
        var seenProjectIDs: Set<UUID> = []
        var projects: [ProjectDefinition] = []
        for project in registeredProjects + [source, target].compactMap({ $0 })
        where seenProjectIDs.insert(project.id).inserted {
            projects.append(project)
        }

        var result = SupabaseConfigurationResolution()
        for project in projects {
            for service in project.services where service.kind == .supabase {
                guard let configuration = service.supabaseConfiguration else {
                    result.errors.append(
                        "「\(project.name)」の \(service.name): \(service.supabaseConfigurationFailureReason)"
                    )
                    continue
                }
                do {
                    let projectID = try configuration.resolveProjectID()
                    if let owner = result.owners[projectID] {
                        result.errors.append(
                            ValidationError.duplicateSupabaseProjectID(
                                projectID: projectID.rawValue,
                                otherProject: owner.projectName
                            ).description
                        )
                        continue
                    }
                    result.configurations[projectID] = configuration
                    result.projectIDsByService[service.id] = projectID
                    result.owners[projectID] = SupabaseConfirmationTarget.Registration(
                        projectName: project.name,
                        serviceName: service.name,
                        configDirectory: configuration.configDirectory
                    )
                } catch {
                    result.errors.append("「\(project.name)」の \(service.name): \(error)")
                }
            }
        }
        return result
    }

    /// 既存スタックを実測し、確認が要るかどうかも含めて今回の処理内容を決める。
    ///
    /// ここは変更操作の前に呼ぶ。承認済みの場合も、実行直前のこの観測結果と
    /// 承認内容（IDの集合・状態・対象設定）が一致しなければ何も変更しない。
    private func resolveSupabasePlan(
        target: ProjectDefinition,
        source: ProjectDefinition?,
        resolution: SupabaseConfigurationResolution,
        approval: SupabaseApproval?
    ) async throws -> SupabaseExecutionPlan? {
        guard let service = target.enabledStartupOrder.first(where: { $0.kind == .supabase })
        else { return nil }
        guard let configuration = service.supabaseConfiguration,
              let projectID = resolution.projectIDsByService[service.id] else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    RuntimeError.managedCommandInvalid(
                        service: service.name,
                        reason: service.supabaseConfigurationFailureReason
                    ).description
                ),
                facts: await facts(source: source, target: target)
            )
        }

        let snapshot = await registry.observeSupabaseStacks()
        try await throwIfUnknown(snapshot, source: source, target: target)

        let plan = makeSupabasePlan(
            service: service,
            configuration: configuration,
            projectID: projectID,
            projectName: target.name,
            snapshot: snapshot,
            skippingStopFor: await managedProjectIDsStoppedWith(source),
            resolution: resolution
        )

        if plan.requiresConfirmation, approval != plan.approval {
            // 未承認、または承認後に対象・状態・設定が変わった。何も変更せず確認し直す。
            throw SwitchFailure(
                reason: .supabaseConfirmationRequired(plan: plan),
                facts: await facts(source: source, target: target)
            )
        }

        var stopProjectIDs = plan.stopTargets.map(\.projectID)
        if plan.target.action == .restart {
            // 対象を含む承認済み全件を停止してから、対象だけを起動する。
            stopProjectIDs.append(projectID)
        }
        return SupabaseExecutionPlan(
            service: service,
            configuration: configuration,
            projectID: projectID,
            action: plan.target.action,
            stopProjectIDs: stopProjectIDs
        )
    }

    private func makeSupabasePlan(
        service: ServiceDefinition,
        configuration: SupabaseServiceConfiguration,
        projectID: SupabaseProjectID,
        projectName: String,
        snapshot: SupabaseStackSnapshot,
        skippingStopFor skipped: Set<SupabaseProjectID>,
        resolution: SupabaseConfigurationResolution
    ) -> SupabaseConfirmationPlan {
        let targetState = snapshot.state(of: projectID)
        let action: SupabaseConfirmationTarget.Action
        switch targetState {
        case .running: action = .adopt
        case .degraded: action = .restart
        case .notRunning, .unknown: action = .start
        }

        // 切替元の管理下スタックは通常の停止処理で止まる。確認を重ねて出さない。
        let stopTargets = snapshot.observations
            .filter { $0.projectID != projectID && !skipped.contains($0.projectID) }
            .map {
                SupabaseConfirmationTarget(
                    projectID: $0.projectID,
                    state: $0.state,
                    action: .stop,
                    registration: resolution.owners[$0.projectID]
                )
            }

        return SupabaseConfirmationPlan(
            serviceID: service.id,
            serviceName: service.name,
            projectName: projectName,
            target: SupabaseConfirmationTarget(
                projectID: projectID,
                state: targetState,
                action: action,
                registration: resolution.owners[projectID]
            ),
            stopTargets: stopTargets,
            snapshot: snapshot,
            fingerprint: configuration.fingerprint
        )
    }

    /// 切替元と一緒に停止される管理下スタックの`project_id`。
    private func managedProjectIDsStoppedWith(
        _ source: ProjectDefinition?
    ) async -> Set<SupabaseProjectID> {
        guard let source else { return [] }
        let managed = await registry.managedSupabaseProjectIDs()
        let sourceServiceIDs = Set(source.services.map(\.id))
        return Set(managed.filter { sourceServiceIDs.contains($0.key) }.values)
    }

    private func throwIfUnknown(
        _ snapshot: SupabaseStackSnapshot,
        source: ProjectDefinition?,
        target: ProjectDefinition?
    ) async throws {
        guard snapshot.hasUnknown else { return }
        throw SwitchFailure(
            reason: .supabaseObservationFailed(
                details: snapshot.failureDetails
            ),
            facts: await facts(source: source, target: target)
        )
    }

    /// 承認済みの`project_id`を1件ずつ停止し、そのつど`notRunning`を確認する。
    /// 途中で失敗したら後続の停止と起動を中断し、停止済みのスタックは再起動しない。
    private func executeSupabaseStops(
        _ plan: SupabaseExecutionPlan,
        source: ProjectDefinition?,
        target: ProjectDefinition,
        resolution: SupabaseConfigurationResolution,
        progress: @escaping ProgressSink
    ) async throws {
        var stopped: [String] = []
        var remaining = plan.stopProjectIDs
        let total = remaining.count
        while !remaining.isEmpty {
            let projectID = remaining.removeFirst()
            progress(
                .stopping(
                    service: "Supabase \(projectID)",
                    index: stopped.count + 1,
                    total: total
                )
            )
            do {
                try await registry.stopUnmanagedStack(
                    using: plan.configuration,
                    projectID: projectID
                )
                stopped.append(projectID.rawValue)
            } catch {
                throw SwitchFailure(
                    reason: .supabaseStopFailed(
                        projectID: projectID.rawValue,
                        reason: "\(error)",
                        stopped: stopped,
                        remaining: remaining.map(\.rawValue)
                    ),
                    facts: await facts(source: source, target: target)
                )
            }
        }

        // 停止が無くても、引き継ぐ直前に対象がまだ`running`かを確かめる。
        guard !plan.stopProjectIDs.isEmpty || plan.action == .adopt else { return }

        let snapshot = await registry.observeSupabaseStacks()
        try await throwIfUnknown(snapshot, source: source, target: target)

        let expected: SupabaseStackState = plan.action == .adopt ? .running : .notRunning
        let latest = makeSupabasePlan(
            service: plan.service,
            configuration: plan.configuration,
            projectID: plan.projectID,
            projectName: target.name,
            snapshot: snapshot,
            skippingStopFor: await managedProjectIDsStoppedWith(source),
            resolution: resolution
        )
        guard latest.target.state == expected, latest.stopTargets.isEmpty else {
            // 停止後に予期しないスタックが現れた、または対象の状態が変わった。
            throw SwitchFailure(
                reason: .supabaseConfirmationRequired(plan: latest),
                facts: await facts(source: source, target: target)
            )
        }
    }

    /// 計画に従ってSupabaseを起動、または引き継ぐ。
    private func beginSupabase(
        _ plan: SupabaseExecutionPlan,
        in target: ProjectDefinition
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        switch plan.action {
        case .adopt:
            adoptedServiceIDs.insert(plan.service.id)
            return try await registry.adoptManagedStack(
                service: plan.service,
                in: target,
                configuration: plan.configuration,
                projectID: plan.projectID,
                relationship: .adopted,
                observation: SupabaseStackObservation(
                    projectID: plan.projectID,
                    state: .running
                )
            )
        case .start, .restart:
            // 停止を確認した以前の引き継ぎを、今回の起動の巻き戻し判定へ持ち越さない。
            clearState(of: plan.service.id)
            return try await registry.startManagedStack(
                service: plan.service,
                in: target,
                configuration: plan.configuration,
                projectID: plan.projectID
            )
        case .stop:
            throw RuntimeError.managedCommandInvalid(
                service: plan.service.name,
                reason: "停止だけの計画から起動はできません。"
            )
        }
    }

    // MARK: - 保存済み手掛かりからの復元

    public enum ManagedRestoreOutcome: Equatable, Sendable {
        /// 実測と一致したため`restored`として管理下へ戻した。
        case restored(SupabaseStackState)
        /// 対象`project_id`のコンテナが無い。手掛かりは破棄してよい。
        case notRunning
        /// 再検証できないため、statusもstopも実行しなかった。手掛かりは残す。
        case skipped(reason: String)
    }

    /// アプリ起動時・フォアグラウンド復帰時の観測。
    /// 確認表示、引き継ぎ、停止は行わず、表示と管理下の実測値だけを更新する。
    @discardableResult
    public func observeSupabaseStacks(
        registeredProjects: [ProjectDefinition]
    ) async -> SupabaseStackSnapshot {
        let resolution = resolveSupabaseConfigurations(
            registeredProjects: registeredProjects,
            source: nil,
            target: nil
        )
        await registry.setKnownSupabaseConfigurations(resolution.configurations)
        return await refreshManagedObservations()
    }

    @discardableResult
    private func refreshManagedObservations() async -> SupabaseStackSnapshot {
        let managed = await registry.managedSupabaseProjectIDs()
        let snapshot = await registry.refreshManagedObservations()
        for (serviceID, projectID) in managed where snapshot.observation(of: projectID).state == .notRunning {
            clearState(of: serviceID)
        }
        return snapshot
    }

    /// 保存済み手掛かりを実測で再検証し、一致した場合だけ`restored`として管理下へ戻す。
    /// 保存値だけで稼働中へは戻さない。一致しなければコマンドを実行しない。
    public func restoreManagedStack(
        hint: ManagedRuntimeHint,
        service: ServiceDefinition,
        in project: ProjectDefinition,
        registeredProjects: [ProjectDefinition]
    ) async -> ManagedRestoreOutcome {
        guard !inFlight else {
            return .skipped(reason: "ほかの起動・停止・切替を実行中です。")
        }
        inFlight = true
        defer { inFlight = false }

        guard hint.relationship != nil else {
            return .skipped(
                reason: "旧形式の手掛かりには`project_id`と設定の記録がないため、状態確認コマンドを実行しません。"
            )
        }
        let resolution = resolveSupabaseConfigurations(
            registeredProjects: registeredProjects,
            source: nil,
            target: project
        )
        await registry.setKnownSupabaseConfigurations(resolution.configurations)

        guard let projectID = resolution.projectIDsByService[service.id] else {
            return .skipped(
                reason: "現在の設定から`project_id`を解決できないため、状態確認コマンドを実行しません。"
            )
        }
        guard let configuration = hint.verifiedConfiguration(
            of: service,
            currentProjectID: projectID
        ) else {
            return .skipped(
                reason: "保存時の設定ディレクトリ・起動コマンド・`project_id`と一致しないため、状態確認コマンドを実行しません。"
            )
        }

        let snapshot = await registry.observeSupabaseStacks()
        let observation = snapshot.observation(of: projectID)

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
                    service: service,
                    in: project,
                    configuration: configuration,
                    projectID: projectID,
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
                    ?? "Supabaseの必須コンテナが揃っていません。"
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
        let services = target.enabledStartupOrder
        guard !services.isEmpty else {
            return SwitchFailure(
                reason: .unsupportedConfiguration(
                    "プロジェクト「\(target.name)」で今回起動するサービスが1つもありません。起動対象を選んでください。"
                ),
                facts: await facts(source: source, target: target)
            )
        }

        // 1開発環境に登録できるSupabaseは1件まで。設定検証と同じ制約をここでも守る。
        let supabaseServices = services.filter { $0.kind == .supabase }
        if supabaseServices.count > 1 {
            return SwitchFailure(
                reason: .unsupportedConfiguration(
                    ValidationError.multipleSupabaseServices(
                        services: supabaseServices.map(\.name)
                    ).description
                ),
                facts: await facts(source: source, target: target)
            )
        }

        for service in services {
            if service.kind == .supabase {
                // 状態の観測と確認は`resolveSupabasePlan`が行う。ここは設定の形式だけを見る。
                if service.supabaseConfiguration == nil {
                    return SwitchFailure(
                        reason: .unsupportedConfiguration(
                            RuntimeError.managedCommandInvalid(
                                service: service.name,
                                reason: service.supabaseConfigurationFailureReason
                            ).description
                        ),
                        facts: await facts(source: source, target: target)
                    )
                }
                continue
            }
            if !service.usesProcessGroupStop {
                return SwitchFailure(
                    reason: .unsupportedConfiguration(
                        RuntimeError.stopCommandUnsupported(service: service.name).description
                    ),
                    facts: await facts(source: source, target: target)
                )
            }
            do {
                _ = try StartupObservationPolicy.spec(for: service)
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
        _ service: ServiceDefinition,
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
        _ service: ServiceDefinition,
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
        let toStop = source.shutdownOrder.filter {
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
            case .stopped:
                clearState(of: service.id)
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
        for service in project.services {
            if await registry.isOccupyingResources(serviceID: service.id) { return }
            if await registry.occupiedProcessGroup(serviceID: service.id) != nil { return }
        }
        for service in project.services {
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
        supabasePlan: SupabaseExecutionPlan?,
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws -> [String] {
        let services = target.enabledStartupOrder
        var startedInThisRun: [ServiceDefinition] = []
        var degraded: [String] = []

        for (index, service) in services.enumerated() {
            progress(.starting(service: service.name, index: index + 1, total: services.count))
            // 同じ設定で再試行したとき、前回の失敗理由を今回の理由へ連結しない。
            failureReasons[service.id] = nil

            let spec: StartupObservationSpec?
            if service.kind == .supabase {
                spec = nil
            } else {
                do {
                    spec = try StartupObservationPolicy.spec(
                        for: service,
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
                events(service.id, .logSessionStarted)
                let observation = ServiceObservation()
                let stream: AsyncStream<ServiceSupervisor.Event>
                if service.kind == .supabase {
                    guard let supabasePlan, supabasePlan.service.id == service.id else {
                        throw RuntimeError.managedCommandInvalid(
                            service: service.name,
                            reason: "既存スタックの実測結果がないため、Supabaseを起動しません。"
                        )
                    }
                    stream = try await beginSupabase(supabasePlan, in: target)
                } else {
                    stream = try await registry.start(service: service, in: target)
                }
                observations[service.id] = observation
                consumers[service.id]?.cancel()
                consumers[service.id] = Task {
                    for await event in stream {
                        // 先に観測へ記録してからUIへ流す。逆にすると、UI が終了を受けて
                        // 状態を問い合わせた時点でこちらがまだ終了を知らないことがある。
                        let observedEvent = await observation.record(event)
                        events(service.id, observedEvent)
                    }
                }
                // 引き継いだスタックは今回起動していない。巻き戻しの対象へ入れない。
                if !adoptedServiceIDs.contains(service.id) {
                    startedInThisRun.append(service)
                }
                failureReasons[service.id] = nil
                residualGroups[service.id] = nil
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

            // Supabaseは起動または引き継ぎの時点で`running`を確認済み。
            // 終了済みの開始コマンドを通常の初期観測へ渡してはいけない。
            if service.kind == .supabase {
                startedServiceIDs.insert(service.id)
                failureReasons[service.id] = nil
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

    private func handleStartFailure(
        _ error: Error,
        service: ServiceDefinition,
        target: ProjectDefinition,
        source: ProjectDefinition?,
        startedInThisRun: [ServiceDefinition],
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
        service: ServiceDefinition,
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
    /// 引き継いだSupabaseは巻き戻さず、残存ありとして停止導線を残す。
    private func rollback(
        _ startedInThisRun: [ServiceDefinition],
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
        service: ServiceDefinition,
        reason: String,
        target: ProjectDefinition,
        source: ProjectDefinition?,
        startedInThisRun: [ServiceDefinition],
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

    private func stopAfterFailedStart(_ service: ServiceDefinition) async {
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
        service: ServiceDefinition,
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
        service: ServiceDefinition,
        in project: ProjectDefinition,
        events: @escaping EventSink = { _, _ in }
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        try await registry.adopt(candidate: candidate, service: service, in: project)
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
                for: service,
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
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws -> ServiceStopOutcome {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        try await registry.adopt(candidate: candidate, service: service, in: project)
        return try await stopRegistered(service: service)
    }

    /// 引き継げないが停止はできるプロセスを停止する。
    ///
    /// 根拠ごとに管理方法が違う。本体が一致しているなら開始時刻で、
    /// 本体が居ないならプロセスグループの同定条件で、送信直前に再検証する。
    public func stopWithoutAdopting(
        _ finding: StoppableProcessFinding,
        service: ServiceDefinition,
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
                service: service,
                in: project
            )
        case .verifiedGroup:
            // 実測し直した証拠で登録する。保存時の古い錨を使うと、
            // 記録後に生まれた子孫を同定できない。
            try await registry.registerResidualGroup(
                hint: finding.hint.updatingGroupEvidence(finding.groupEvidence),
                service: service,
                in: project
            )
        }
        return try await stopRegistered(service: service)
    }

    private func stopRegistered(service: ServiceDefinition) async throws -> ServiceStopOutcome {
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
    /// 呼び出し側は事前確認を必ず挟む（MVP_SPEC 12章）。
    public func forceStop(
        serviceIDs: [UUID],
        in project: ProjectDefinition
    ) async throws -> [UUID: ServiceStopOutcome] {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        var outcomes: [UUID: ServiceStopOutcome] = [:]
        for serviceID in serviceIDs {
            guard let service = project.service(id: serviceID) else { continue }
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
        _ service: ServiceDefinition,
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
        // managed Supabaseのdegraded / unknownは、プロセスのPGIDを持たない。
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
        if service.kind != .supabase,
           startedServiceIDs.contains(service.id),
           observations[service.id] == nil {
            return .failed(reason: "引き継いだプロセスが停止操作なしに終了しました（終了コードは取得できません）")
        }
        if !project.isEnabledNow(service.id) { return .excluded }
        return .stopped
    }

    public func projectFact(_ project: ProjectDefinition) async -> ProjectFact {
        var services: [ServiceFact] = []
        for service in project.services {
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
            services: services
        )
    }

    /// 実測で「対象外」のものだけを除く。今回追加起動したプロセスの失敗も集計する。
    private func projectPhase(
        _ project: ProjectDefinition,
        services: [ServiceFact]
    ) -> ProjectPhase {
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) })

        if services.contains(where: { $0.phase == .residual }) { return .residual }

        let servicesInThisRun = project.services.map { service -> (definition: ServiceDefinition, phase: ServicePhase) in
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
