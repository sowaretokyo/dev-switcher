import Darwin
import Foundation

/// 画面へ出すための実測値。本体を管理できない場合でも、握られている資源は表示する。
public struct ServiceRuntimeSnapshot: Equatable, Sendable {
    /// 管理できる本体があるときだけ入る。残存グループでは nil。
    public let processID: pid_t?
    public let processGroupID: pid_t?
    /// ポート観測の成否。`.unavailable` をUIまで保持する。
    public let observedPortRecord: ObservedPortRecord
    /// 観測できた場合のPID・address付き詳細。
    public let observedPorts: [ObservedPort]
    public let startedAt: Date?

    public init(
        processID: pid_t?,
        processGroupID: pid_t?,
        observedPortRecord: ObservedPortRecord,
        observedPorts: [ObservedPort],
        startedAt: Date?
    ) {
        self.processID = processID
        self.processGroupID = processGroupID
        self.observedPortRecord = observedPortRecord
        self.observedPorts = observedPorts
        self.startedAt = startedAt
    }
}

/// 停止結果。停止できなかった理由を文章として保持する。
/// 「止まらなかった」とだけ返すと、利用者が次に何をすればよいか決められない。
public enum ServiceStopOutcome: Equatable, Sendable {
    /// 停止した。引き継いだプロセスは子ではないため終了状態を取得できず nil になる。
    case stopped(ExitStatus?)
    case residual(processGroupID: pid_t, reason: String)
    /// 未回収リーダーによるPGID予約を失った。古いPGIDへは送信もdrain待ちもしない。
    case ownershipLost(reason: String)

    public var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }
}

/// 終了時の手掛かりを完全な一覧として作れなかった理由。
/// 1件でも欠けた一覧を保存すると、次回起動時の回収手段を失うため全体を失敗させる。
public enum RuntimeHintSnapshotError: Error, Equatable, Sendable, CustomStringConvertible {
    case ownerUnavailable(serviceID: UUID)
    case runtimeUnavailable(serviceID: UUID, serviceName: String)
    case evidenceUnavailable(serviceID: UUID, serviceName: String, reason: String)

    public var description: String {
        switch self {
        case let .ownerUnavailable(serviceID):
            "サービス \(serviceID.uuidString) の所有情報を取得できないため、再検証の手掛かりを保存できません。"
        case let .runtimeUnavailable(serviceID, serviceName):
            "サービス「\(serviceName)」（\(serviceID.uuidString)）の実行情報を取得できないため、再検証の手掛かりを保存できません。"
        case let .evidenceUnavailable(serviceID, serviceName, reason):
            "サービス「\(serviceName)」（\(serviceID.uuidString)）のプロセスグループを再同定できないため、再検証の手掛かりを保存できません。\n\(reason)"
        }
    }
}

/// actorは`await`をまたいだ再入を防がないため、起動・停止の排他は明示的なフラグで守る。
/// プロジェクト間の排他をUIだけに依存させないため、この層でも実プロセスから判定する。
/// 自分で起動したプロセスと、再起動後に引き継いだプロセスの両方を同じ入口で扱う。
public actor RuntimeRegistry {
    private struct ServiceOwner {
        let projectID: UUID
        let projectName: String
        let serviceName: String
    }

    /// 起動したものと引き継いだものでは、停止時に使える手段が違う。
    /// 引き継いだプロセスは子ではないので回収予約を持てず、同一性の再検証だけが頼りになる。
    /// 本体が居ない残存グループは、さらにグループ同定の再検証だけが頼りになる。
    fileprivate enum Handle {
        case launched(ServiceSupervisor)
        case adopted(AdoptedSupervisor)
        case residualGroup(ResidualGroupSupervisor)
    }

    private var handles: [UUID: Handle] = [:]
    /// 残存グループの手掛かり。同定条件を広げないため、記録時刻を書き換えずに持ち回る。
    private var residualHints: [UUID: RuntimeHint] = [:]
    private var owners: [UUID: ServiceOwner] = [:]
    private var operationInFlight = false
    private var cachedEnvironment: ShellEnvironment?
    private let portPollInterval: Duration
    private let logDirectoryOverride: URL?
    private let environmentLoader: ShellEnvironmentLoader
    private let portProbe: ServiceSupervisor.PortProbe
    private let signalSender: ServiceSupervisor.SignalSender
    private let groupStateProbe: ServiceSupervisor.ProcessGroupStateProbe
    private let startAbstimeProbe: ServiceSupervisor.StartAbstimeProbe
    private let bootSessionProbe: ServiceSupervisor.BootSessionProbe

    /// テストごとにログインシェルを起動しないよう、取得処理を差し替え可能にする。
    public typealias ShellEnvironmentLoader = @Sendable () async throws -> ShellEnvironment

    public init(
        portPollInterval: Duration = .seconds(2),
        logDirectory: URL? = nil,
        environmentLoader: @escaping ShellEnvironmentLoader = { try await LoginShellEnvironment.load() },
        portProbe: @escaping ServiceSupervisor.PortProbe = { processGroupID in
            try await PortInspector.listeningPorts(processGroupID: processGroupID)
        },
        signalSender: @escaping ServiceSupervisor.SignalSender = { kill(-$0, $1) },
        groupStateProbe: @escaping ServiceSupervisor.ProcessGroupStateProbe = {
            ProcessInspector.processGroupState($0)
        },
        startAbstimeProbe: @escaping ServiceSupervisor.StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping ServiceSupervisor.BootSessionProbe = {
            ProcessInspector.bootSessionID()
        }
    ) {
        self.portPollInterval = portPollInterval
        self.logDirectoryOverride = logDirectory
        self.environmentLoader = environmentLoader
        self.portProbe = portProbe
        self.signalSender = signalSender
        self.groupStateProbe = groupStateProbe
        self.startAbstimeProbe = startAbstimeProbe
        self.bootSessionProbe = bootSessionProbe
    }

    /// 取得失敗時に意図しない実行ファイルを選ばないよう、最小PATHへフォールバックしない。
    @discardableResult
    public func environment(reload: Bool = false) async throws -> ShellEnvironment {
        if !reload, let cachedEnvironment {
            return cachedEnvironment
        }
        let loaded = try await environmentLoader()
        cachedEnvironment = loaded
        return loaded
    }

    // MARK: - 起動

    public func start(
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        // 終了コマンドを持つサービスは Post-MVP の managed command として扱う。
        // プロセスグループ停止へ黙って倒すと、停止したつもりでサービスが残る。
        guard service.usesProcessGroupStop else {
            throw RuntimeError.stopCommandUnsupported(service: service.name)
        }

        if let existing = handles[service.id] {
            if await existing.isRunning() {
                throw RuntimeError.alreadyRunning(service: service.name)
            }
            // 親が終了していても孫が残っていることがある。ここで supervisor を
            // 差し替えると、残ったプロセスグループへの停止手段を失う。
            if await existing.isOccupyingResources(),
               let processGroupID = await existing.processGroupID() {
                throw RuntimeError.residualProcessesRemain(
                    service: service.name,
                    processGroupID: processGroupID
                )
            }
        }

        // 保存状態は古くなりうるため、プロジェクト間の排他は実プロセスから判断する。
        if let running = await runningProject(), running.projectID != project.id {
            throw RuntimeError.otherProjectRunning(
                running: running.projectName,
                requested: project.name
            )
        }

        let environment = try await environment()
        let resolved = try ExecutableResolver.resolve(
            service.start,
            searchPath: environment.searchPath
        )

        let supervisor = ServiceSupervisor(
            serviceID: service.id,
            serviceName: service.name,
            command: resolved,
            logDirectory: try logDirectoryOverride ?? ApplicationPaths.logDirectory(),
            portPollInterval: portPollInterval,
            groupStateProbe: groupStateProbe,
            signalSender: signalSender,
            portProbe: portProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        )
        handles[service.id] = .launched(supervisor)
        owners[service.id] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: service.name
        )
        return try await supervisor.start(environment: environment.variables)
    }

    /// 再起動後の引き継ぎ。実測で照合済みの候補だけを受け取る。
    /// この経路では新しいプロセスを起動しない。既存プロセスを管理下へ置くだけ。
    func adopt(
        candidate: HandoffCandidate,
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws {
        try await adopt(
            identity: candidate.identity,
            processGroupID: candidate.hint.processGroupID,
            observedPorts: candidate.observedPorts,
            evidence: candidate.evidence,
            service: service,
            in: project
        )
    }

    func adopt(
        identity: ProcessIdentity,
        processGroupID: pid_t,
        observedPorts: [ObservedPort],
        evidence: ProcessGroupEvidence,
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        try await checkAdoptionPreconditions(service: service, in: project)

        let verifiedEvidence = try verifyHandoffCandidate(
            identity: identity,
            processGroupID: processGroupID,
            evidence: evidence,
            service: service
        )

        let supervisor = AdoptedSupervisor(
            serviceID: service.id,
            serviceName: service.name,
            identity: identity,
            processGroupID: processGroupID,
            observedPorts: observedPorts,
            evidence: verifiedEvidence,
            startAbstimeProbe: startAbstimeProbe,
            groupStateProbe: groupStateProbe,
            bootSessionProbe: bootSessionProbe,
            signalSender: signalSender,
            portProbe: portProbe
        )
        // 引き継いだ直後に本体が消えていたら、管理下へ置かずエラーにする。
        guard await supervisor.isRunning() else {
            throw RuntimeError.identityMismatch(
                service: service.name,
                pid: identity.pid
            )
        }
        handles[service.id] = .adopted(supervisor)
        residualHints[service.id] = nil
        owners[service.id] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: service.name
        )
    }

    /// 本体が終了し、プロセスグループにだけ残りがある状態を管理下へ置く。
    ///
    /// 引き継ぎ（稼働中として扱うこと）はしない。停止手段を持たせるためだけの登録。
    /// 同定条件を広げないため、手掛かりの記録時刻はそのまま保持する。
    func registerResidualGroup(
        hint: RuntimeHint,
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        try await checkAdoptionPreconditions(service: service, in: project)

        let verifiedEvidence: ProcessGroupEvidence
        switch ProcessGroupIdentification.identify(
            processGroupID: hint.processGroupID,
            evidence: hint.groupEvidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        ) {
        case let .matched(evidence):
            verifiedEvidence = evidence
        case .empty:
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: "プロセスグループは既に空です。"
            )
        case let .notIdentified(reason), let .unobservable(reason):
            throw RuntimeError.invalidHandoff(service: service.name, reason: reason)
        }

        let supervisor = ResidualGroupSupervisor(
            processGroupID: hint.processGroupID,
            evidence: verifiedEvidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe,
            signalSender: signalSender,
            portProbe: portProbe
        )
        handles[service.id] = .residualGroup(supervisor)
        residualHints[service.id] = hint.updatingGroupEvidence(verifiedEvidence)
        owners[service.id] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: service.name
        )
    }

    private func checkAdoptionPreconditions(
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws {
        if let existing = handles[service.id], await existing.isOccupyingResources() {
            throw RuntimeError.alreadyRunning(service: service.name)
        }
        if let running = await runningProject(), running.projectID != project.id {
            throw RuntimeError.otherProjectRunning(
                running: running.projectName,
                requested: project.name
            )
        }
    }

    /// `HandoffCandidate` もプロセス変化との競合を受ける未信頼入力として扱い、
    /// Registryへ登録する直前に本体・PGID・証拠をまとめて再検証する。
    private func verifyHandoffCandidate(
        identity: ProcessIdentity,
        processGroupID: pid_t,
        evidence: ProcessGroupEvidence,
        service: ServiceDefinition
    ) throws -> ProcessGroupEvidence {
        guard identity.pid == processGroupID else {
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: "本体 PID \(identity.pid) とプロセスグループ \(processGroupID) が一致しません。"
            )
        }
        guard evidence.anchors.contains(identity.anchor) else {
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: "実測した証拠に本体 PID \(identity.pid) の錨が含まれていません。"
            )
        }

        switch ProcessGroupIdentification.identify(
            processGroupID: processGroupID,
            evidence: evidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        ) {
        case let .matched(verifiedEvidence):
            guard verifiedEvidence.anchors.contains(identity.anchor) else {
                throw RuntimeError.invalidHandoff(
                    service: service.name,
                    reason: "登録直前に本体 PID \(identity.pid) が対象グループから外れました。"
                )
            }
            return verifiedEvidence
        case .empty:
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: "登録直前にプロセスグループが空になりました。"
            )
        case let .notIdentified(reason), let .unobservable(reason):
            throw RuntimeError.invalidHandoff(service: service.name, reason: reason)
        }
    }

    // MARK: - 停止

    public func stop(
        service: ServiceDefinition,
        grace: Duration = .seconds(10)
    ) async throws -> ServiceStopOutcome {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard let handle = handles[service.id] else {
            throw RuntimeError.notRunning(service: service.name)
        }
        return try await handle.stop(grace: grace)
    }

    /// 強制終了。利用者が対象を確認して明示的に選んだ場合にのみ呼ぶ。
    public func forceStop(
        service: ServiceDefinition,
        grace: Duration = .seconds(5)
    ) async throws -> ServiceStopOutcome {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard let handle = handles[service.id] else {
            throw RuntimeError.notRunning(service: service.name)
        }
        return try await handle.forceStop(grace: grace)
    }

    // MARK: - 観測

    public func isRunning(serviceID: UUID) async -> Bool {
        guard let handle = handles[serviceID] else { return false }
        return await handle.isRunning()
    }

    public func observedRuntime(serviceID: UUID) async -> ObservedRuntime? {
        guard let handle = handles[serviceID] else { return nil }
        return await handle.observedRuntime()
    }

    /// 画面表示に使う実測値。
    ///
    /// `ObservedRuntime` は本体の同一性を前提にしているため、リーダーが居ない
    /// 残存グループでは作れない。それでもプロセスグループと実測ポートは分かるので、
    /// 表示できる情報を落とさないよう別の型で返す。
    public func runtimeSnapshot(serviceID: UUID) async -> ServiceRuntimeSnapshot? {
        guard let handle = handles[serviceID] else { return nil }
        return await handle.runtimeSnapshot()
    }

    /// ポートを今すぐ実測し直す。停止前のゲート用スナップショットを取る直前に呼ぶ。
    /// 失敗は握りつぶさず送出する。「ポートなし」と扱ってはいけない。
    public func refreshPorts(serviceID: UUID) async throws {
        guard let handle = handles[serviceID] else { return }
        try await handle.refreshPorts()
    }

    public func runningServiceIDs() async -> Set<UUID> {
        var running: Set<UUID> = []
        for (id, handle) in handles where await handle.isRunning() {
            running.insert(id)
        }
        return running
    }

    /// 実際に起動または引き継いでいるサービス。停止対象と、ゲート検証1のポート源になる。
    /// 設定上ポートを持つかどうかではなく、資源を握っているかで決める。
    public func activeRuntimes(projectID: UUID) async -> [ObservedRuntime] {
        var runtimes: [ObservedRuntime] = []
        for (serviceID, handle) in handles {
            guard owners[serviceID]?.projectID == projectID else { continue }
            guard await handle.isOccupyingResources() else { continue }
            guard let runtime = await handle.observedRuntime() else { continue }
            runtimes.append(runtime)
        }
        return runtimes
    }

    /// 資源を握っているサービスID。`ObservedRuntime`を取得できないものも取りこぼさない。
    public func occupyingServiceIDs(projectID: UUID) async -> Set<UUID> {
        var ids: Set<UUID> = []
        for (serviceID, handle) in handles {
            guard owners[serviceID]?.projectID == projectID else { continue }
            if await handle.isOccupyingResources() { ids.insert(serviceID) }
        }
        return ids
    }

    public func runningProjectID() async -> UUID? {
        await runningProject()?.projectID
    }

    public func ownerProjectID(serviceID: UUID) -> UUID? {
        owners[serviceID]?.projectID
    }

    public func occupiedProcessGroup(serviceID: UUID) async -> pid_t? {
        guard let handle = handles[serviceID],
              await handle.isOccupyingResources()
        else { return nil }
        return await handle.processGroupID()
    }

    /// ポート番号から「それが自分の管理下のサービスか」を引く。
    /// 外部プロセスを自動終了しないため、所有区分の判定にはこの対応表だけを使う。
    public func ownership(ofPID pid: pid_t) async -> (serviceID: UUID, serviceName: String)? {
        for (serviceID, handle) in handles {
            guard let runtime = await handle.observedRuntime() else { continue }
            let ownsPID = runtime.identity.pid == pid
                || runtime.observedPorts.contains { $0.pid == pid }
            guard ownsPID, let owner = owners[serviceID] else { continue }
            return (serviceID, owner.serviceName)
        }
        return nil
    }

    /// 次回起動時の再検証に渡す手掛かり。稼働状態そのものではない。
    ///
    /// 条件は「本体が生きているか」ではなく「資源を握っているか」。
    /// 親が終了しても孫がプロセスグループに残ることがあり、そのとき手掛かりを残さないと、
    /// 再起動後に停止手段のない残存プロセスになる。
    /// ポートを持たない孫はゲートでも検出できないため、ここで取りこぼすと回収不能になる。
    ///
    /// 錨は保存時点で測り直す。古い錨を固定で持ち回ると、記録後に生まれた子孫が
    /// 次回の同定に使えず、本体が終了したあとに回収できなくなる。
    public func runtimeHints() async throws -> [RuntimeHint] {
        var hints: [RuntimeHint] = []
        for (serviceID, handle) in handles {
            guard await handle.isOccupyingResources() else { continue }
            guard let owner = owners[serviceID] else {
                throw RuntimeHintSnapshotError.ownerUnavailable(serviceID: serviceID)
            }

            // 残存グループは本体の同一性を持たない。登録時の手掛かりを土台に、
            // 証拠だけを最新のものへ差し替える。
            if let residualHint = residualHints[serviceID] {
                let evidence = try await handle.currentGroupEvidence(
                    serviceID: serviceID,
                    serviceName: owner.serviceName
                )
                hints.append(
                    residualHint.updating(
                        groupEvidence: evidence,
                        observedPorts: await handle.observedPortRecord()
                    )
                )
                continue
            }

            guard let runtime = await handle.observedRuntime() else {
                throw RuntimeHintSnapshotError.runtimeUnavailable(
                    serviceID: serviceID,
                    serviceName: owner.serviceName
                )
            }
            let evidence = try await handle.currentGroupEvidence(
                serviceID: serviceID,
                serviceName: owner.serviceName
            )
            hints.append(
                RuntimeHint(
                    projectID: owner.projectID,
                    serviceID: serviceID,
                    serviceName: owner.serviceName,
                    processGroupID: runtime.processGroupID,
                    leader: runtime.identity.anchor,
                    groupEvidence: evidence,
                    executablePath: runtime.identity.executablePath,
                    workingDirectory: runtime.identity.workingDirectory,
                    // 実測できていなければ `.unavailable`。空配列と混同しない。
                    observedPorts: await handle.observedPortRecord()
                )
            )
        }
        return hints.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }
    }

    private func runningProject() async -> ServiceOwner? {
        for (serviceID, handle) in handles {
            guard await handle.isOccupyingResources(), let owner = owners[serviceID] else {
                continue
            }
            return owner
        }
        return nil
    }
}

fileprivate extension RuntimeRegistry.Handle {
    func isRunning() async -> Bool {
        switch self {
        case let .launched(supervisor): await supervisor.isRunning
        case let .adopted(supervisor): await supervisor.isRunning()
        // 管理できる本体が無いものを「稼働中」とは言わない。
        case .residualGroup: false
        }
    }

    func isOccupyingResources() async -> Bool {
        switch self {
        case let .launched(supervisor): await supervisor.isOccupyingResources()
        case let .adopted(supervisor): await supervisor.isOccupyingResources()
        case let .residualGroup(supervisor):
            switch await supervisor.identify() {
            case .matched: true
            case .empty: false
            // 同定できないものを自分の占有として主張しない。
            case .notIdentified: false
            // 観測できない間は「居ない」と決めつけない。
            case .unobservable: true
            }
        }
    }

    func processGroupID() async -> pid_t? {
        switch self {
        case let .launched(supervisor): await supervisor.processGroupID
        case let .adopted(supervisor): await supervisor.processGroupID
        case let .residualGroup(supervisor): await supervisor.processGroupID
        }
    }

    /// 手掛かりへ書く証拠。保存のたびに測り直し、後発の子孫を錨へ含める。
    ///
    /// 起動した子は未回収のゾンビが PID を予約しているため、この時点の PGID が
    /// 再利用されていないことが保証されている。引き継ぎ・残存グループでは、
    /// 錨の照合が成功した時点でだけ更新済みの証拠を返す。
    func currentGroupEvidence(
        serviceID: UUID,
        serviceName: String
    ) async throws -> ProcessGroupEvidence {
        switch self {
        case let .launched(supervisor):
            guard let evidence = await supervisor.captureGroupEvidence() else {
                throw RuntimeHintSnapshotError.evidenceUnavailable(
                    serviceID: serviceID,
                    serviceName: serviceName,
                    reason: "起動セッションまたはプロセスの開始時刻を観測できません。"
                )
            }
            return evidence
        case let .adopted(supervisor):
            return try await supervisor.identifyGroup().snapshotEvidence(
                serviceID: serviceID,
                serviceName: serviceName
            )
        case let .residualGroup(supervisor):
            return try await supervisor.identify().snapshotEvidence(
                serviceID: serviceID,
                serviceName: serviceName
            )
        }
    }

    /// 手掛かりへ書くポート。実測できていなければ `.unavailable`。
    func observedPortRecord() async -> ObservedPortRecord {
        switch self {
        case let .launched(supervisor): await supervisor.observedPortRecord
        case let .adopted(supervisor): await supervisor.observedPorts
        case let .residualGroup(supervisor): await supervisor.observedPorts
        }
    }

    func observedRuntime() async -> ObservedRuntime? {
        switch self {
        case let .launched(supervisor): await supervisor.observedRuntime
        case let .adopted(supervisor): await supervisor.observedRuntime
        // 本体の同一性を持たないため、実測状態としては何も返さない。
        case .residualGroup: nil
        }
    }

    func refreshPorts() async throws {
        switch self {
        case let .launched(supervisor): try await supervisor.refreshPorts()
        case let .adopted(supervisor): try await supervisor.refreshPorts()
        case let .residualGroup(supervisor): try await supervisor.refreshPorts()
        }
    }

    /// 表示できる実測値。本体が無くても、握られている資源は返す。
    func runtimeSnapshot() async -> ServiceRuntimeSnapshot? {
        switch self {
        case .launched, .adopted:
            guard let runtime = await observedRuntime() else { return nil }
            return ServiceRuntimeSnapshot(
                processID: runtime.identity.pid,
                processGroupID: runtime.processGroupID,
                observedPortRecord: await observedPortRecord(),
                observedPorts: runtime.observedPorts,
                startedAt: runtime.startedAt
            )
        case let .residualGroup(supervisor):
            // 本体が居ないので PID は出さない。停止に必要なのはプロセスグループの方。
            let record = await supervisor.observedPorts
            return ServiceRuntimeSnapshot(
                processID: nil,
                processGroupID: await supervisor.processGroupID,
                observedPortRecord: record,
                observedPorts: await supervisor.observedPortDetails,
                startedAt: nil
            )
        }
    }

    func stop(grace: Duration) async throws -> ServiceStopOutcome {
        switch self {
        case let .launched(supervisor):
            switch try await supervisor.stop(grace: grace) {
            case let .exited(status):
                return .stopped(status)
            case let .residual(processGroupID):
                return .residual(
                    processGroupID: processGroupID,
                    reason: "通常終了（SIGTERM）の猶予内にプロセスグループが空になりませんでした。"
                )
            case .ownershipLost:
                return .ownershipLost(
                    reason: "プロセスグループの所有権を失ったため、停止結果を判定できません。"
                )
            }
        case let .adopted(supervisor):
            return await supervisor.stop(grace: grace)
        case let .residualGroup(supervisor):
            return await supervisor.stop(grace: grace)
        }
    }

    func forceStop(grace: Duration) async throws -> ServiceStopOutcome {
        switch self {
        case let .launched(supervisor):
            switch try await supervisor.forceStop(grace: grace) {
            case let .exited(status):
                return .stopped(status)
            case let .residual(processGroupID):
                return .residual(
                    processGroupID: processGroupID,
                    reason: "強制終了（SIGKILL）後もプロセスグループにプロセスが残っています。"
                )
            case .ownershipLost:
                return .ownershipLost(
                    reason: "プロセスグループの所有権を失ったため、強制終了を行いませんでした。"
                )
            }
        case let .adopted(supervisor):
            return await supervisor.forceStop(grace: grace)
        case let .residualGroup(supervisor):
            return await supervisor.forceStop(grace: grace)
        }
    }
}

private extension ProcessGroupIdentification.Result {
    /// 保存用の証拠へ変換する。引き継ぎと残存グループで失敗の扱いを分岐させない。
    func snapshotEvidence(
        serviceID: UUID,
        serviceName: String
    ) throws -> ProcessGroupEvidence {
        switch self {
        case let .matched(evidence):
            return evidence
        case .empty:
            throw RuntimeHintSnapshotError.evidenceUnavailable(
                serviceID: serviceID,
                serviceName: serviceName,
                reason: "プロセスグループは観測の途中で空になりました。"
            )
        case let .notIdentified(reason), let .unobservable(reason):
            throw RuntimeHintSnapshotError.evidenceUnavailable(
                serviceID: serviceID,
                serviceName: serviceName,
                reason: reason
            )
        }
    }
}
