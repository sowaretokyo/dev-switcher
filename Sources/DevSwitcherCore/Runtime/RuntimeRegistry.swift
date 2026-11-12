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
    case stopped(ExitStatus?, warning: String? = nil)
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
            L10n.text("サービス \(serviceID.uuidString) の所有情報を取得できないため、再検証の手掛かりを保存できません。")
        case let .runtimeUnavailable(serviceID, serviceName):
            L10n.text("サービス「\(serviceName)」（\(serviceID.uuidString)）の実行情報を取得できないため、再検証の手掛かりを保存できません。")
        case let .evidenceUnavailable(serviceID, serviceName, reason):
            L10n.text("サービス「\(serviceName)」（\(serviceID.uuidString)）のプロセスグループを再同定できないため、再検証の手掛かりを保存できません。\n\(reason)")
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
        case managed(ManagedStackSupervisor)
    }

    private var handles: [UUID: Handle] = [:]
    private var stopWarningMessages: [UUID: String] = [:]
    private var processDefinitions: [UUID: ServiceDefinition] = [:]
    private var stopCommandParents: [UUID: UUID] = [:]
    private let stopCommandTimeout: Duration
    /// 残存グループの手掛かり。同定条件を広げないため、記録時刻を書き換えずに持ち回る。
    private var residualHints: [UUID: RuntimeHint] = [:]
    private var owners: [UUID: ServiceOwner] = [:]
    private var operationInFlight = false
    private var cachedEnvironment: ShellEnvironment?
    private let portPollInterval: Duration
    private let logDirectoryOverride: URL?
    private let environmentLoader: ShellEnvironmentLoader
    private let identityProbe: ServiceSupervisor.ProcessIdentityProbe
    private let portProbe: ServiceSupervisor.PortProbe
    private let signalSender: ServiceSupervisor.SignalSender
    private let groupStateProbe: ServiceSupervisor.ProcessGroupStateProbe
    private let startAbstimeProbe: ServiceSupervisor.StartAbstimeProbe
    private let bootSessionProbe: ServiceSupervisor.BootSessionProbe
    /// 管理対象スタックの種類ごとの観測・起動・停止。外部コマンドの実行は driver へ集約する。
    private let stackDrivers: [ManagedStackType: any ManagedStackDriver]
    /// 設定が既知のスタック。driver が観測の精度を上げる対象を決める。
    /// 登録済み開発環境の変更に追従するため、操作の直前に呼び出し側が入れ替える。
    private var knownStacks: [ManagedStackIdentity: ResolvedManagedStack] = [:]

    /// テストごとにログインシェルを起動しないよう、取得処理を差し替え可能にする。
    public typealias ShellEnvironmentLoader = @Sendable () async throws -> ShellEnvironment

    public init(
        portPollInterval: Duration = .seconds(2),
        stopCommandTimeout: Duration = .seconds(30),
        logDirectory: URL? = nil,
        environmentLoader: @escaping ShellEnvironmentLoader = { try await LoginShellEnvironment.load() },
        identityProbe: @escaping ServiceSupervisor.ProcessIdentityProbe = { pid, workingDirectory in
            ProcessInspector.identity(pid: pid, workingDirectory: workingDirectory)
        },
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
        },
        stackDrivers: [ManagedStackType: any ManagedStackDriver]? = nil
    ) {
        self.portPollInterval = portPollInterval
        self.stopCommandTimeout = stopCommandTimeout
        self.logDirectoryOverride = logDirectory
        self.environmentLoader = environmentLoader
        self.identityProbe = identityProbe
        self.portProbe = portProbe
        self.signalSender = signalSender
        self.groupStateProbe = groupStateProbe
        self.startAbstimeProbe = startAbstimeProbe
        self.bootSessionProbe = bootSessionProbe
        // 実装を渡されない場合だけ、実Docker・実CLIを使う既定の driver を組み立てる。
        let drivers = stackDrivers ?? [
            .dockerCompose: DockerComposeStackDriver(runner: ManagedStackProcessCommandRunner(environmentProvider: environmentLoader)),
            .supabase: SupabaseStackDriver(
                inventory: SupabaseDockerInventory(environmentProvider: environmentLoader),
                runner: ManagedStackProcessCommandRunner(environmentProvider: environmentLoader)
            ),
        ]
        // キーと driver の種類がずれていると、別の種類のスタックへコマンドを送る。
        for (type, driver) in drivers where driver.type != type {
            preconditionFailure(L10n.text("\(type.rawValue) のキーに \(driver.type.rawValue) の driver が登録されています。"))
        }
        self.stackDrivers = drivers
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

        if ProcessCommandClassification.supabaseStart(service.start) == .certain {
            throw RuntimeError.managedCommandInvalid(service: service.name, reason: L10n.text("Supabase の起動は管理対象スタックとして登録してください。"))
        }
        // 管理対象スタックは実測と確認を伴う専用経路から起動する。
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

        if await isOccupyingResources(serviceID: service.id), let pgid = await occupiedProcessGroup(serviceID: service.id) {
            throw RuntimeError.residualProcessesRemain(service: service.name, processGroupID: pgid)
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
            identityProbe: identityProbe,
            groupStateProbe: groupStateProbe,
            signalSender: signalSender,
            portProbe: portProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        )
        processDefinitions[service.id] = service
        stopWarningMessages[service.id] = nil
        handles[service.id] = .launched(supervisor)
        owners[service.id] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: service.name
        )
        return try await supervisor.start(environment: environment.variables)
    }

    // MARK: - 管理対象スタック

    /// 登録済みスタックの解決済み設定を入れ替える。観測の精度だけに影響する。
    public func setKnownStacks(_ stacks: [ManagedStackIdentity: ResolvedManagedStack]) {
        knownStacks = stacks
    }

    /// 観測対象の種類。登録済みまたは管理下のスタックがある種類だけ。
    /// スタックを使っていない利用者の操作ごとに外部コマンドを実行しないため。
    private func typesToObserve() -> [ManagedStackType] {
        var types = Set(knownStacks.keys.map(\.type))
        for handle in handles.values {
            guard case let .managed(supervisor) = handle else { continue }
            types.insert(supervisor.identity.type)
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    /// driver へ渡す、同じ種類の既知スタック。
    private func knownStacks(of type: ManagedStackType) -> [ResolvedManagedStack] {
        Handle.known(knownStacks, of: type)
    }

    /// 1種類を実測する。driver が無い種類は観測全体の失敗として返し、停止中へ倒さない。
    private func observe(type: ManagedStackType) async -> ManagedStackSnapshot {
        guard let driver = stackDrivers[type] else {
            return ManagedStackSnapshot(
                type: type,
                unobservable: L10n.text("\(type.displayName)を観測する手段が登録されていません。")
            )
        }
        return await driver.observe(known: knownStacks(of: type))
    }

    /// 1スタックだけの再観測。同じ種類の全スタックを実測したうえで対象を取り出す。
    private func observe(_ identity: ManagedStackIdentity) async -> ManagedStackObservation {
        await observe(type: identity.type).observation(of: identity)
    }

    private func driver(
        for type: ManagedStackType,
        stackName: String
    ) throws -> any ManagedStackDriver {
        guard let driver = stackDrivers[type] else {
            throw RuntimeError.managedCommandInvalid(
                service: stackName,
                reason: L10n.text("\(type.displayName)を操作する手段が登録されていません。")
            )
        }
        return driver
    }

    /// 登録済みまたは管理下のスタックがある種類を実測する。
    /// 停止済みの管理関係は解除し、新しい管理関係は取得しない。
    public func observeManagedStacks() async -> ManagedStackSnapshot {
        var snapshot = ManagedStackSnapshot()
        for type in typesToObserve() {
            snapshot = snapshot.merging(await observe(type: type))
        }
        for (serviceID, handle) in handles {
            guard case let .managed(supervisor) = handle else { continue }
            await supervisor.update(observation: snapshot.observation(of: supervisor.identity))
            await releaseStoppedManagedHandle(serviceID: serviceID, handle: handle)
        }
        return snapshot
    }

    /// 表示用の最新実測値。読み出すだけでは外部コマンドを実行しない。
    /// 種類ごとの最新値を合わせ、最新値の無い種類は未観測とする。どの種類にも無ければ nil。
    public func latestManagedStackSnapshot() async -> ManagedStackSnapshot? {
        var snapshot: ManagedStackSnapshot?
        for type in stackDrivers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let driver = stackDrivers[type],
                  let latest = await driver.latestSnapshot else { continue }
            snapshot = snapshot.map { $0.merging(latest) } ?? latest
        }
        return snapshot
    }

    /// 管理下のスタックの実測結果を、1回の観測でまとめて更新する。
    ///
    /// 登録済みのスタックも管理下のスタックも無い場合は外部コマンドを実行しない。
    /// スタックを使っていない利用者の操作へ、毎回の`docker ps`を足さないため。
    @discardableResult
    public func refreshManagedObservations() async -> ManagedStackSnapshot {
        guard !knownStacks.isEmpty
            || handles.values.contains(where: \.isManaged)
        else {
            return ManagedStackSnapshot()
        }
        return await observeManagedStacks()
    }

    /// 今回Dev Switcherが起動する経路。開始コマンドと`running`確認の成功後だけ`launched`として登録する。
    public func startManagedStack(
        _ stack: ResolvedManagedStack,
        in project: ProjectDefinition
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        try await checkManagedPreconditions(stackID: stack.stackID, stackName: stack.stackName, in: project)
        let driver = try driver(for: stack.type, stackName: stack.stackName)

        // preflight後に別ターミナルから起動される競合を縮める。
        // ここで占有が見つかっても、Dev Switcher由来とはみなさない。
        let beforeStart = await observe(stack.identity)
        guard beforeStart.state == .notRunning else {
            throw RuntimeError.managedStartOwnershipUnconfirmed(
                stack: stack.stackName,
                identity: stack.identity,
                state: beforeStart.state,
                reason: beforeStart.detail ?? L10n.text("開始コマンドの実行直前に既存スタックを検出しました。")
            )
        }

        let logs: [LogLine]
        do {
            logs = try await driver.start(stack, known: knownStacks(of: stack.type))
        } catch {
            let afterFailure = await observe(stack.identity)
            guard afterFailure.state == .notRunning else {
                let failureDetail = [
                    L10n.text("開始処理の失敗: \(error)"),
                    afterFailure.detail.map { L10n.text("実測の詳細: \($0)") },
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                throw RuntimeError.managedStartOwnershipUnconfirmed(
                    stack: stack.stackName,
                    identity: stack.identity,
                    state: afterFailure.state,
                    reason: failureDetail
                )
            }
            throw error
        }

        // コマンド成功とrunning確認が揃ったこの時点で初めて停止権限を取得する。
        let supervisor = registerManaged(
            stack,
            in: project,
            relationship: .launched,
            observation: ManagedStackObservation(identity: stack.identity, state: .running),
            driver: driver
        )
        let stream = await supervisor.makeEventStream()
        await supervisor.emit(logs: logs)
        return stream
    }

    /// 既存スタックを引き継ぐ経路。起動コマンドは実行しない。
    /// 利用者の承認、または保存済み手掛かりの再検証を通った場合にだけ呼ぶ。
    public func adoptManagedStack(
        _ stack: ResolvedManagedStack,
        in project: ProjectDefinition,
        relationship: ManagedStackRelationship,
        observation: ManagedStackObservation
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard relationship != .launched else {
            throw RuntimeError.managedCommandInvalid(
                service: stack.stackName,
                reason: L10n.text("引き継ぎ経路では `launched` として登録できません。")
            )
        }
        try await checkManagedPreconditions(stackID: stack.stackID, stackName: stack.stackName, in: project)
        let driver = try driver(for: stack.type, stackName: stack.stackName)

        let supervisor = registerManaged(
            stack,
            in: project,
            relationship: relationship,
            observation: observation,
            driver: driver
        )
        return await supervisor.makeEventStream()
    }

    /// 承認済みの既存スタックを、対象のIDだけ指定して停止する。
    ///
    /// 管理下に無いスタックへ実行できる唯一の経路。承認内容の照合は呼び出し側が行い、
    /// ここでは排他と「対象限定の停止＋停止確認」だけを担当する。
    /// `context`はコマンドの実行に使う設定で、`identity`と同じ種類でなければならない。
    public func stopUnmanagedStack(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack
    ) async throws {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard context.type == identity.type else {
            throw ManagedStackIdentityError.typeMismatch(expected: context.type, actual: identity.type)
        }
        let driver = try driver(for: identity.type, stackName: context.stackName)
        _ = try await driver.stop(identity, using: context, known: knownStacks(of: identity.type))
        // 同じスタックを管理していたhandleが残っていたら、実測に合わせて外す。
        for (serviceID, handle) in handles {
            guard case let .managed(supervisor) = handle,
                  supervisor.identity == identity else { continue }
            await supervisor.update(observation: ManagedStackObservation(identity: identity, state: .notRunning))
            await releaseStoppedManagedHandle(serviceID: serviceID, handle: handle)
        }
    }

    /// 停止の確認で停止権限も失効する。同じIDが後から現れても、以前の承認を再利用しない。
    /// `unknown`や停止失敗で残ったスタックは、停止導線と手掛かりを維持する。
    private func releaseStoppedManagedHandle(serviceID: UUID, handle: Handle) async {
        guard case let .managed(supervisor) = handle,
              await supervisor.observation.state == .notRunning,
              case let .managed(current) = handles[serviceID], current === supervisor else { return }
        handles[serviceID] = nil
        owners[serviceID] = nil
        await supervisor.finishEvents()
    }

    public func managedRelationship(stackID: UUID) async -> ManagedStackRelationship? {
        guard case let .managed(supervisor) = handles[stackID] else { return nil }
        return supervisor.relationship
    }

    public func managedObservation(stackID: UUID) async -> ManagedStackObservation? {
        guard case let .managed(supervisor) = handles[stackID] else { return nil }
        return await supervisor.observation
    }

    /// 管理下のスタックのID。停止対象の重複判定に使う。
    public func managedStackIdentities() async -> [UUID: ManagedStackIdentity] {
        var result: [UUID: ManagedStackIdentity] = [:]
        for (serviceID, handle) in handles {
            guard case let .managed(supervisor) = handle else { continue }
            result[serviceID] = supervisor.identity
        }
        return result
    }

    private func registerManaged(
        _ stack: ResolvedManagedStack,
        in project: ProjectDefinition,
        relationship: ManagedStackRelationship,
        observation: ManagedStackObservation,
        driver: any ManagedStackDriver
    ) -> ManagedStackSupervisor {
        let supervisor = ManagedStackSupervisor(
            stack: stack,
            relationship: relationship,
            observation: observation,
            driver: driver
        )
        handles[stack.stackID] = .managed(supervisor)
        residualHints[stack.stackID] = nil
        owners[stack.stackID] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: stack.stackName
        )
        return supervisor
    }

    private func checkManagedPreconditions(
        stackID: UUID,
        stackName: String,
        in project: ProjectDefinition
    ) async throws {
        if let existing = handles[stackID], await existing.isOccupyingResources() {
            throw RuntimeError.alreadyRunning(service: stackName)
        }
        if let running = await runningProject(), running.projectID != project.id {
            throw RuntimeError.otherProjectRunning(
                running: running.projectName,
                requested: project.name
            )
        }
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
        if let parent = candidate.hint.stopCommandFor { stopCommandParents[service.id] = parent }
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
        processDefinitions[service.id] = service
        handles[service.id] = .adopted(supervisor)
        residualHints[service.id] = nil
        owners[service.id] = ServiceOwner(
            projectID: project.id,
            projectName: project.name,
            serviceName: service.name
        )
    }

    /// 引き継ぎ済みの通常プロセスが書き続けている、アプリ管理下のログへ接続する。
    func resumeAdoptedLogs(
        serviceID: UUID,
        events: @escaping @Sendable (ServiceSupervisor.Event) -> Void
    ) async throws {
        guard case let .adopted(supervisor) = handles[serviceID] else {
            throw RuntimeError.invalidHandoff(
                service: serviceID.uuidString, reason: L10n.text("ログを再開する引き継ぎ済みプロセスがありません。")
            )
        }
        let files = ServiceLogFiles(
            directory: try logDirectoryOverride ?? ApplicationPaths.logDirectory(),
            serviceID: serviceID
        )
        try await supervisor.resumeLogs(files: files, events: events)
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
                reason: L10n.text("プロセスグループは既に空です。")
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
        processDefinitions[service.id] = service
        if let parent = hint.stopCommandFor { stopCommandParents[service.id] = parent }
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
                reason: L10n.text("本体 PID \(identity.pid) とプロセスグループ \(processGroupID) が一致しません。")
            )
        }
        guard evidence.anchors.contains(identity.anchor) else {
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: L10n.text("実測した証拠に本体 PID \(identity.pid) の錨が含まれていません。")
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
                    reason: L10n.text("登録直前に本体 PID \(identity.pid) が対象グループから外れました。")
                )
            }
            return verifiedEvidence
        case .empty:
            throw RuntimeError.invalidHandoff(
                service: service.name,
                reason: L10n.text("登録直前にプロセスグループが空になりました。")
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
        try await stop(id: service.id, name: service.name, grace: grace, force: false)
    }

    /// 強制終了。利用者が対象を確認して明示的に選んだ場合にのみ呼ぶ。
    public func forceStop(
        service: ServiceDefinition,
        grace: Duration = .seconds(5)
    ) async throws -> ServiceStopOutcome {
        try await stop(id: service.id, name: service.name, grace: grace, force: true)
    }

    /// 停止方法によらず、排他と停止後の管理解除を同じ経路で行う。
    private func stop(
        id: UUID,
        name: String,
        grace: Duration,
        force: Bool
    ) async throws -> ServiceStopOutcome {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }
        stopWarningMessages[id] = nil

        let auxiliary = stopCommandParents.filter { $0.value == id }.map(\.key)
        for commandID in auxiliary {
            guard let commandHandle = handles[commandID], await commandHandle.isOccupyingResources() else { continue }
            let result = force ? try await commandHandle.forceStop(grace: grace, known: knownStacks) : try await commandHandle.stop(grace: grace, known: knownStacks)
            if !result.isStopped { return result }
        }
        guard let handle = handles[id] else {
            if !auxiliary.isEmpty { return .stopped(nil) }
            throw RuntimeError.notRunning(service: name)
        }
        if !auxiliary.isEmpty, await handle.isOccupyingResources() == false {
            await handle.completeCommandStopObservation()
            return .stopped(nil)
        }
        if !force, case let .command(stopCommand)? = processDefinitions[id]?.stopMethod {
            do {
                let result = try await stopUsingCommand(stopCommand, id: id, name: name, handle: handle, grace: grace)
                var auxiliaryRemains = false
                for (commandID, parent) in stopCommandParents where parent == id {
                    if let child = handles[commandID], await child.isOccupyingResources() { auxiliaryRemains = true }
                }
                if !auxiliaryRemains { await handle.completeCommandStopObservation() }
                return result
            } catch {
                await handle.completeCommandStopObservation()
                throw error
            }
        }
        do {
            let outcome = if force {
                try await handle.forceStop(grace: grace, known: knownStacks)
            } else {
                try await handle.stop(grace: grace, known: knownStacks)
            }
            await handle.completeCommandStopObservation()
            await releaseStoppedManagedHandle(serviceID: id, handle: handle)
            return outcome
        } catch {
            // コマンドが失敗しても、再観測で停止を確認できた場合は管理を解除する。
            await releaseStoppedManagedHandle(serviceID: id, handle: handle)
            throw error
        }
    }

    private func stopUsingCommand(_ command: CommandSpec, id: UUID, name: String, handle: Handle, grace: Duration) async throws -> ServiceStopOutcome {
        guard try await handle.prepareCommandStop() else { return .stopped(nil) }
        let shell = try await environment()
        let resolved = try ExecutableResolver.resolve(command, searchPath: shell.searchPath)
        let commandID = UUID()
        let logDirectory = try logDirectoryOverride ?? ApplicationPaths.logDirectory()
        let files = ServiceLogFiles(directory: logDirectory, serviceID: id)
        let stopCommandName = L10n.text("\(name) の停止コマンド")
        let supervisor = ServiceSupervisor(serviceID: commandID, serviceName: stopCommandName, command: resolved,
            logDirectory: logDirectory, sharedLogFiles: files, appendOutput: true,
            identityProbe: identityProbe, groupStateProbe: groupStateProbe, signalSender: signalSender,
            portProbe: portProbe, startAbstimeProbe: startAbstimeProbe, bootSessionProbe: bootSessionProbe)
        handles[commandID] = .launched(supervisor)
        processDefinitions[commandID] = ServiceDefinition(id: commandID, name: stopCommandName, ports: [], start: command, enabledByDefault: false, failurePolicy: .block)
        stopCommandParents[commandID] = id
        guard let owner = owners[id] else { throw RuntimeHintSnapshotError.ownerUnavailable(serviceID: id) }
        owners[commandID] = ServiceOwner(projectID: owner.projectID, projectName: owner.projectName, serviceName: stopCommandName)
        _ = try await supervisor.start(environment: shell.variables)
        var warning: String?
        if let status = await supervisor.waitForCommandExit(timeout: stopCommandTimeout) {
            if !status.isSuccess { warning = L10n.text("停止コマンドが失敗しました（\(status.description)）。") }
        } else {
            warning = L10n.text("停止コマンドが \(Int(stopCommandTimeout.seconds)) 秒以内に終了しませんでした。停止コマンドのグループへ SIGTERM を送りました。")
            _ = try await supervisor.stop(grace: grace)
        }
        if let message = warning {
            do {
                let output = try FileHandle(forWritingTo: files.standardError)
                defer { try? output.close() }
                try output.seekToEnd()
                try output.write(contentsOf: Data(("\n[Dev Switcher] " + message + "\n").utf8))
            } catch {
                warning = message + L10n.text("\n停止コマンドの結果をログへ書き込めません。\n\(error)")
            }
        }
        stopWarningMessages[id] = warning
        let outcome = await handle.waitForCommandStop(grace: grace)
        if await supervisor.isOccupyingResources(), let pgid = await supervisor.processGroupID {
            return .residual(processGroupID: pgid, reason: (warning.map { $0 + "\n" } ?? "") + L10n.text("停止コマンドのプロセスグループが残っています。対象グループと停止コマンドを保持しています。"))
        }
        switch outcome {
        case let .stopped(status, _): return .stopped(status, warning: warning)
        case let .residual(pgid, reason): return .residual(processGroupID: pgid, reason: (warning.map { $0 + "\n" } ?? "") + reason)
        case .ownershipLost: return outcome
        }
    }

    public func stopWarnings(projectID: UUID) -> [String] {
        stopWarningMessages.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let owner = owners[id], owner.projectID == projectID, let warning = stopWarningMessages[id] else { return nil }
            return "\(owner.serviceName): \(warning)"
        }
    }

    func registerStopCommandRole(_ hint: RuntimeHint) throws {
        guard let parent = hint.stopCommandFor else { return }
        guard parent != hint.serviceID, let command = hint.stopCommand, processDefinitions[hint.serviceID]?.start == command else {
            throw RuntimeError.invalidHandoff(service: hint.serviceName, reason: L10n.text("停止コマンドの設定が一致しません。"))
        }
        stopCommandParents[hint.serviceID] = parent
    }

    public func start(service: LaunchUnit, in project: ProjectDefinition) async throws -> AsyncStream<ServiceSupervisor.Event> {
        guard let process = service.processDefinition else {
            throw RuntimeError.managedCommandInvalid(service: service.name, reason: L10n.text("スタックは専用の起動処理を使用してください。"))
        }
        return try await start(service: process, in: project)
    }
    public func stop(service: LaunchUnit, grace: Duration = .seconds(10)) async throws -> ServiceStopOutcome {
        try await stop(id: service.id, name: service.name, grace: grace, force: false)
    }
    public func forceStop(service: LaunchUnit, grace: Duration = .seconds(5)) async throws -> ServiceStopOutcome {
        try await stop(id: service.id, name: service.name, grace: grace, force: true)
    }

    // MARK: - 観測

    /// 自分で起動した子の終了結果。引き継いだプロセスには終了コードを持たない。
    func observedExit(serviceID: UUID) async -> ServiceSupervisor.ExitRecord? {
        guard case let .launched(supervisor) = handles[serviceID] else { return nil }
        return await supervisor.observedExit
    }

    public func isRunning(serviceID: UUID) async -> Bool {
        guard let handle = handles[serviceID] else { return false }
        return await handle.isRunning()
    }

    public func isOccupyingResources(serviceID: UUID) async -> Bool {
        if let handle = handles[serviceID], await handle.isOccupyingResources() { return true }
        for (id, parent) in stopCommandParents where parent == serviceID {
            if let handle = handles[id], await handle.isOccupyingResources() { return true }
        }
        return false
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
        var auxiliary: [ServiceRuntimeSnapshot] = []
        for (id, parent) in stopCommandParents.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where parent == serviceID {
            guard let handle = handles[id], await handle.isOccupyingResources(), let snapshot = await handle.runtimeSnapshot() else { continue }
            auxiliary.append(snapshot)
        }
        let original = await handles[serviceID]?.runtimeSnapshot()
        guard !auxiliary.isEmpty else { return original }
        let originalActive = await handles[serviceID]?.isOccupyingResources() == true
        let snapshots = (originalActive ? original.map { [$0] } ?? [] : []) + auxiliary
        let representative = originalActive ? original : auxiliary.first
        let ports = snapshots.flatMap(\.observedPorts)
        let record: ObservedPortRecord = snapshots.allSatisfy { $0.observedPortRecord.observed != nil }
            ? .observed(Array(Set(snapshots.flatMap { $0.observedPortRecord.observed! })).sorted()) : .unavailable
        return ServiceRuntimeSnapshot(processID: originalActive ? original?.processID : nil, processGroupID: representative?.processGroupID,
            observedPortRecord: record, observedPorts: ports, startedAt: originalActive ? original?.startedAt : nil)
    }

    /// ポートを今すぐ実測し直す。停止前のゲート用スナップショットを取る直前に呼ぶ。
    /// 失敗は握りつぶさず送出する。「ポートなし」と扱ってはいけない。
    public func refreshPorts(serviceID: UUID) async throws {
        if let handle = handles[serviceID] { try await handle.refreshPorts() }
        for (id, parent) in stopCommandParents where parent == serviceID {
            if let handle = handles[id], await handle.isOccupyingResources() { try await handle.refreshPorts() }
        }
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
            if await handle.isOccupyingResources() { ids.insert(stopCommandParents[serviceID] ?? serviceID) }
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
        if let handle = handles[serviceID], await handle.isOccupyingResources() { return await handle.processGroupID() }
        for (id, parent) in stopCommandParents where parent == serviceID {
            if let handle = handles[id], await handle.isOccupyingResources() { return await handle.processGroupID() }
        }
        return nil
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
            // managed commandにはPID/PGIDが無い。別形式の手掛かりとして保存する。
            if handle.isManaged { continue }
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
        for index in hints.indices {
            if let parent = stopCommandParents[hints[index].serviceID] {
                hints[index].stopCommandFor = parent
                hints[index].stopCommand = processDefinitions[hints[index].serviceID]?.start
            }
        }
        return hints.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }
    }

    /// 管理対象スタックはPIDを持たないため、次回再検証する対象だけを別形式で返す。
    /// 稼働状態ではなく、種類・ID・構成同一性・管理関係を保存する。
    public func managedRuntimeHints() async throws -> [ManagedStackHint] {
        var hints: [ManagedStackHint] = []
        for (serviceID, handle) in handles {
            guard case let .managed(supervisor) = handle else { continue }
            guard await handle.isOccupyingResources() else { continue }
            guard let owner = owners[serviceID] else {
                throw RuntimeHintSnapshotError.ownerUnavailable(serviceID: serviceID)
            }
            hints.append(
                ManagedStackHint(
                    projectID: owner.projectID,
                    stackID: serviceID,
                    stackName: owner.serviceName,
                    configuration: supervisor.stack.configuration,
                    // 再検証で復元したものも、次回はやはり実測で確かめる。
                    relationship: supervisor.relationship
                )
            )
        }
        return hints.sorted { $0.stackID.uuidString < $1.stackID.uuidString }
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
    /// driver へ渡す、同じ種類の既知スタック。
    static func known(
        _ stacks: [ManagedStackIdentity: ResolvedManagedStack],
        of type: ManagedStackType
    ) -> [ResolvedManagedStack] {
        stacks.values
            .filter { $0.type == type }
            .sorted { $0.identity < $1.identity }
    }

    func isRunning() async -> Bool {
        switch self {
        case let .launched(supervisor): await supervisor.isRunning
        case let .adopted(supervisor): await supervisor.isRunning()
        // 管理できる本体が無いものを「稼働中」とは言わない。
        case .residualGroup: false
        case let .managed(supervisor): await supervisor.isRunning
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
        // `degraded`と`unknown`も資源を握っている可能性がある。停止導線を消さない。
        case let .managed(supervisor): await supervisor.isOccupyingResources
        }
    }

    var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }

    func processGroupID() async -> pid_t? {
        switch self {
        case let .launched(supervisor): await supervisor.processGroupID
        case let .adopted(supervisor): await supervisor.processGroupID
        case let .residualGroup(supervisor): await supervisor.processGroupID
        case .managed: nil
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
                    reason: L10n.text("起動セッションまたはプロセスの開始時刻を観測できません。")
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
        case .managed:
            throw RuntimeHintSnapshotError.evidenceUnavailable(
                serviceID: serviceID,
                serviceName: serviceName,
                reason: L10n.text("管理コマンドにはプロセスグループの証拠がありません。")
            )
        }
    }

    /// 手掛かりへ書くポート。実測できていなければ `.unavailable`。
    func observedPortRecord() async -> ObservedPortRecord {
        switch self {
        case let .launched(supervisor): await supervisor.observedPortRecord
        case let .adopted(supervisor): await supervisor.observedPorts
        case let .residualGroup(supervisor): await supervisor.observedPorts
        case .managed: .unavailable
        }
    }

    func observedRuntime() async -> ObservedRuntime? {
        switch self {
        case let .launched(supervisor): await supervisor.observedRuntime
        case let .adopted(supervisor): await supervisor.observedRuntime
        // 本体の同一性を持たないため、実測状態としては何も返さない。
        case .residualGroup: nil
        case .managed: nil
        }
    }

    func refreshPorts() async throws {
        switch self {
        case let .launched(supervisor): try await supervisor.refreshPorts()
        case let .adopted(supervisor): try await supervisor.refreshPorts()
        case let .residualGroup(supervisor): try await supervisor.refreshPorts()
        case .managed: break
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
        case let .managed(supervisor):
            guard await supervisor.isRunning else { return nil }
            return ServiceRuntimeSnapshot(
                processID: nil,
                processGroupID: nil,
                observedPortRecord: .unavailable,
                observedPorts: [],
                startedAt: nil
            )
        }
    }

    func completeCommandStopObservation() async {
        switch self {
        case let .launched(supervisor): await supervisor.completeCommandStopObservation()
        case let .adopted(supervisor): await supervisor.completeCommandStopObservation()
        case .residualGroup, .managed: break
        }
    }

    func prepareCommandStop() async throws -> Bool {
        switch self {
        case let .launched(supervisor): try await supervisor.prepareCommandStop()
        case let .adopted(supervisor): try await supervisor.prepareCommandStop()
        case let .residualGroup(supervisor): try await supervisor.prepareCommandStop()
        case .managed: throw RuntimeError.operationInProgress
        }
    }
    func waitForCommandStop(grace: Duration) async -> ServiceStopOutcome {
        switch self {
        case let .launched(supervisor): await supervisor.waitForCommandStop(grace: grace)
        case let .adopted(supervisor): await supervisor.waitForCommandStop(grace: grace)
        case let .residualGroup(supervisor): await supervisor.waitForCommandStop(grace: grace)
        case .managed: .ownershipLost(reason: L10n.text("スタックは通常プロセスとして停止できません。"))
        }
    }

    func stop(
        grace: Duration,
        known: [ManagedStackIdentity: ResolvedManagedStack]
    ) async throws -> ServiceStopOutcome {
        switch self {
        case let .launched(supervisor):
            switch try await supervisor.stop(grace: grace) {
            case let .exited(status):
                return .stopped(status)
            case let .residual(processGroupID):
                return .residual(
                    processGroupID: processGroupID,
                    reason: L10n.text("通常終了（SIGTERM）の猶予内にプロセスグループが空になりませんでした。")
                )
            case .ownershipLost:
                return .ownershipLost(
                    reason: L10n.text("プロセスグループの所有権を失ったため、停止結果を判定できません。")
                )
            }
        case let .adopted(supervisor):
            return await supervisor.stop(grace: grace)
        case let .residualGroup(supervisor):
            return await supervisor.stop(grace: grace)
        case let .managed(supervisor):
            return try await supervisor.stop(known: Self.known(known, of: supervisor.identity.type))
        }
    }

    func forceStop(
        grace: Duration,
        known: [ManagedStackIdentity: ResolvedManagedStack]
    ) async throws -> ServiceStopOutcome {
        switch self {
        case let .launched(supervisor):
            switch try await supervisor.forceStop(grace: grace) {
            case let .exited(status):
                return .stopped(status)
            case let .residual(processGroupID):
                return .residual(
                    processGroupID: processGroupID,
                    reason: L10n.text("強制終了（SIGKILL）後もプロセスグループにプロセスが残っています。")
                )
            case .ownershipLost:
                return .ownershipLost(
                    reason: L10n.text("プロセスグループの所有権を失ったため、強制終了を行いませんでした。")
                )
            }
        case let .adopted(supervisor):
            return await supervisor.forceStop(grace: grace)
        case let .residualGroup(supervisor):
            return await supervisor.forceStop(grace: grace)
        case let .managed(supervisor):
            // 外部リソースにSIGKILLは対応しない。対象限定の停止コマンドを再試行する。
            return try await supervisor.stop(known: Self.known(known, of: supervisor.identity.type))
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
                reason: L10n.text("プロセスグループは観測の途中で空になりました。")
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
