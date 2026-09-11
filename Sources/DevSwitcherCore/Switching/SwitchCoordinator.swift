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
        case .logSessionStarted, .started, .ports, .warning:
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
    public func start(
        _ project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(stopping: nil, starting: project, progress: progress, events: events)
    }

    /// プロジェクトを停止する（切替先なし）。
    public func stop(
        _ project: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(stopping: project, starting: nil, progress: progress, events: events)
    }

    /// 切替。停止 → ポート解放の確認 → 起動の順を崩さない。
    public func switchProject(
        from source: ProjectDefinition,
        to target: ProjectDefinition,
        progress: @escaping ProgressSink = { _ in },
        events: @escaping EventSink = { _, _ in }
    ) async throws -> SwitchOutcome {
        try await run(
            stopping: source,
            starting: target,
            progress: progress,
            events: events
        )
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
        guard !inFlight else {
            throw SwitchFailure(
                reason: .operationInProgress,
                facts: await facts(source: project, target: nil)
            )
        }
        inFlight = true
        defer { inFlight = false }

        guard project.service(id: service.id) != nil else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "サービス「\(service.name)」はプロジェクト「\(project.name)」に登録されていません。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        guard project.isEnabledNow(service.id) else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "サービス「\(service.name)」は現在の起動対象から外れています。起動対象にしてから再起動してください。"
                ),
                facts: await facts(source: project, target: nil)
            )
        }
        guard service.kind != .supabase else {
            throw SwitchFailure(
                reason: .unsupportedConfiguration(
                    "Supabaseは通常プロセスと停止・状態確認の方法が異なるため、プロセス単体の再起動はできません。"
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
        if await registry.occupiedProcessGroup(serviceID: service.id) != nil {
            let ports = try await stopForRestart(service, in: project, progress: progress)
            let recovery = RestartRecovery(portsToRelease: ports, failureReason: nil)
            restartRecoveries[service.id] = recovery
            restartRecovery = recovery
        } else {
            restartRecovery = restartRecoveries[service.id]
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
            throw await restartStartFailure(error, service: service, project: project)
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

    /// 再起動後の手掛かりを保存できなかった場合に、今回起動した1件だけを戻す。
    /// UIから通常の単体停止としては公開しない。
    public func stopAfterUnsavedRestart(
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

    // MARK: - 本体

    private func run(
        stopping source: ProjectDefinition?,
        starting target: ProjectDefinition?,
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

        // 起動前の検証。実行できない設定は、停止を始める前に落とす。
        // 停止してから「起動できません」と言うと、どちらも動いていない状態を作る。
        if let target, let failure = await preflight(target, source: source) {
            throw failure
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
        let degraded = try await startPhase(
            target,
            source: source,
            progress: progress,
            events: events
        )

        progress(.completed)
        return SwitchOutcome(
            facts: await facts(source: source, target: target),
            degradedServices: degraded
        )
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

        for service in services {
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
        progress: @escaping ProgressSink
    ) async throws -> [Int] {
        let occupying = await registry.occupyingServiceIDs(projectID: source.id)
        let toStop = source.shutdownOrder.filter { occupying.contains($0.id) }

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
                if await registry.occupiedProcessGroup(serviceID: service.id) == nil {
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
            if await registry.isRunning(serviceID: service.id) { return }
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
        progress: @escaping ProgressSink,
        events: @escaping EventSink
    ) async throws -> [String] {
        let services = target.enabledStartupOrder
        var startedInThisRun: [ServiceDefinition] = []
        var degraded: [String] = []

        for (index, service) in services.enumerated() {
            progress(.starting(service: service.name, index: index + 1, total: services.count))

            let spec: StartupObservationSpec
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

            do {
                // 前回停止時のログは原因調査のため残し、新しい起動を試す時点で区切る。
                events(service.id, .logSessionStarted)
                let observation = ServiceObservation()
                let stream = try await registry.start(service: service, in: target)
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
                startedInThisRun.append(service)
                failureReasons[service.id] = nil
                residualGroups[service.id] = nil
            } catch {
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

            progress(.observingStartup(service: service.name))
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

    /// 単体再起動の開始失敗では、再起動前から動いていた他サービスを巻き戻さない。
    private func restartStartFailure(
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
            // 今回このrunで起動したものだけを、起動順の逆に停止する。
            // 以前から動いていたプロセスまで巻き込まない。
            for started in startedInThisRun.reversed() {
                progress(.rollingBack(service: started.name))
                await stopAfterFailedStart(started)
            }
            throw SwitchFailure(
                reason: .startFailed(service: service.name, reason: reason),
                facts: await facts(source: source, target: target)
            )
        }
    }

    private func stopAfterFailedStart(_ service: ServiceDefinition) async {
        guard await registry.occupiedProcessGroup(serviceID: service.id) != nil else {
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
        in project: ProjectDefinition
    ) async throws {
        guard !inFlight else { throw RuntimeError.operationInProgress }
        inFlight = true
        defer { inFlight = false }

        try await registry.adopt(candidate: candidate, service: service, in: project)
        clearState(of: service.id)

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
            guard await registry.occupiedProcessGroup(serviceID: serviceID) != nil else {
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
        if let reason = failureReasons[service.id] { return .failed(reason: reason) }
        if await registry.isRunning(serviceID: service.id) {
            return startedServiceIDs.contains(service.id) ? .healthy : .running
        }
        // 起動したプロセスは終了したのに、孫がプロセスグループに残っていることがある。
        // これを「失敗」や「停止中」と表示すると、資源を握ったままなのに
        // 停止の導線が出ず、画面から復旧できなくなる。
        if await registry.occupiedProcessGroup(serviceID: service.id) != nil {
            return .residual
        }
        // 停止操作なしに終了していたら「停止中」で塗りつぶさない。
        // 終了コード0でも、頼んでいない終了はサービスの成功ではない。
        if let exit = await observations[service.id]?.exit, !exit.requestedByUser {
            return .failed(reason: "停止操作なしに終了しました（\(exit.status.description)）")
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

    /// 「対象外」は失敗でも一部停止でもない。判定から必ず除外する（DESIGN.md 決定 h）。
    private func projectPhase(
        _ project: ProjectDefinition,
        services: [ServiceFact]
    ) -> ProjectPhase {
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) })

        if services.contains(where: { $0.phase == .residual }) { return .residual }

        let enabled = project.services.filter { project.isEnabledNow($0.id) }
        guard !enabled.isEmpty else { return .stopped }

        let facts = enabled.compactMap { byID[$0.id] }
        if facts.allSatisfy({ $0.phase == .healthy }) { return .running }
        if facts.allSatisfy({ $0.phase == .stopped || $0.phase == .excluded }) { return .stopped }
        if facts.contains(where: { $0.phase == .starting || $0.phase == .running }) {
            return .starting
        }

        // 稼働できていないサービスのうち、1つでも block があればプロジェクトの失敗。
        // continue だけなら一部停止（稼働中の一種）。
        let unavailable = enabled.filter { byID[$0.id]?.phase != .healthy }
        if let blocking = unavailable.first(where: { $0.failurePolicy == .block }) {
            let reason: String
            if case let .failed(detail) = byID[blocking.id]?.phase {
                reason = detail
            } else {
                reason = "サービス「\(blocking.name)」が起動できていません。"
            }
            return .failed(reason: reason)
        }
        return .degraded(stoppedServices: unavailable.map(\.name))
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
