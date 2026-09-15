import Darwin
import Foundation

/// 親だけを止めて孫を残さないよう、サービスを独立したプロセスグループとして所有する。
/// ポート設定は停止対象の同一性を証明できないため、停止判断には使わない。
/// 親の同一性を観測できた場合は開始時刻を再検証し、観測前に終了した場合はリーダーを
/// 回収せずPGIDの再利用を防ぐ。所有権を手放したPGIDへは二度とシグナルを送らない。
public actor ServiceSupervisor {
    struct ExitRecord: Equatable, Sendable {
        let status: ExitStatus
        let requestedByUser: Bool
    }

    public enum Event: Sendable {
        /// 新しい起動試行の境界。UIはここで前回セッションのログを消す。
        case logSessionStarted
        case started(ObservedRuntime)
        case log([LogLine])
        case ports([ObservedPort])
        case warning(String)
        /// 終了コード0でも、停止要求なしの終了を成功扱いしないため操作意図を伴う。
        /// `startupConfirmed` はCoordinatorが初期観測を通過させた場合だけtrueにする。
        case exited(status: ExitStatus, requestedByUser: Bool, startupConfirmed: Bool)
    }

    public enum StopOutcome: Equatable, Sendable {
        case exited(ExitStatus)
        case residual(processGroupID: pid_t)
        case ownershipLost
    }

    /// 観測不能時の取消経路を再現できるよう、同一性の取得処理を差し替え可能にする。
    public typealias ProcessIdentityProbe = @Sendable (pid_t, URL) -> ProcessIdentity?

    /// 取得失敗時の挙動を試験できるよう、プロセスグループの観測も差し替え可能にする。
    public typealias ProcessGroupStateProbe = @Sendable (pid_t) -> ProcessInspector.ProcessGroupState

    /// 「所有権を失ったら送らない」ことをテストで確かめられるよう、送出も差し替え可能にする。
    public typealias SignalSender = @Sendable (pid_t, Int32) -> Int32
    public typealias PortProbe = @Sendable (pid_t) async throws -> [ObservedPort]
    public typealias StartAbstimeProbe = @Sendable (pid_t) -> ProcessInspector.StartAbstimeObservation
    public typealias BootSessionProbe = @Sendable () -> String?

    public let serviceID: UUID
    public let serviceName: String
    public let logFiles: ServiceLogFiles

    private let command: ResolvedCommand
    private let portPollInterval: Duration
    private let identityProbe: ProcessIdentityProbe
    private let groupStateProbe: ProcessGroupStateProbe
    private let signalSender: SignalSender
    private let portProbe: PortProbe
    private let startAbstimeProbe: StartAbstimeProbe
    private let bootSessionProbe: BootSessionProbe

    private var child: ChildProcess?
    private var tail: LogFileTail?
    /// nilは所有権を手放した状態を表し、以後のシグナル送出を禁止する。
    private var launchedProcessGroupID: pid_t?
    private var runtime: ObservedRuntime?
    private var continuation: AsyncStream<Event>.Continuation?
    private var portTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var lastWarning: String?
    /// ポートの実測結果。「0件だった」と「実測できなかった」を区別して保持する。
    private var portRecord: ObservedPortRecord = .unavailable
    private var didExit = false
    private var stopRequested = false
    private var exitRecord: ExitRecord?

    public init(
        serviceID: UUID,
        serviceName: String,
        command: ResolvedCommand,
        logDirectory: URL,
        portPollInterval: Duration = .seconds(2),
        identityProbe: @escaping ProcessIdentityProbe = { pid, workingDirectory in
            ProcessInspector.identity(pid: pid, workingDirectory: workingDirectory)
        },
        groupStateProbe: @escaping ProcessGroupStateProbe = { processGroupID in
            ProcessInspector.processGroupState(processGroupID)
        },
        signalSender: @escaping SignalSender = { processGroupID, signal in
            kill(-processGroupID, signal)
        },
        portProbe: @escaping PortProbe = { processGroupID in
            try await PortInspector.listeningPorts(processGroupID: processGroupID)
        },
        startAbstimeProbe: @escaping StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping BootSessionProbe = { ProcessInspector.bootSessionID() }
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.command = command
        self.logFiles = ServiceLogFiles(directory: logDirectory, serviceID: serviceID)
        self.portPollInterval = portPollInterval
        self.identityProbe = identityProbe
        self.groupStateProbe = groupStateProbe
        self.signalSender = signalSender
        self.portProbe = portProbe
        self.startAbstimeProbe = startAbstimeProbe
        self.bootSessionProbe = bootSessionProbe
    }

    public var observedRuntime: ObservedRuntime? { runtime }

    /// 手掛かりへ書くポート。実測できていなければ `.unavailable`。
    public var observedPortRecord: ObservedPortRecord { portRecord }

    public var isRunning: Bool {
        guard child != nil else { return false }
        return observedExit == nil
    }

    /// 通知の消費を待たず、終了を観測した時点の結果と停止意図を返す。
    var observedExit: ExitRecord? {
        if let exitRecord { return exitRecord }
        guard let status = child?.currentStatus else { return nil }
        return recordExit(status)
    }

    private func recordExit(_ status: ExitStatus) -> ExitRecord {
        if let exitRecord { return exitRecord }
        let record = ExitRecord(status: status, requestedByUser: stopRequested)
        exitRecord = record
        return record
    }

    public var processGroupID: pid_t? { launchedProcessGroupID }

    /// 親の観測前に孫だけが残る場合もあるため、占有判定には`ObservedRuntime`ではなくPGIDを使う。
    /// 動作中メンバーが消えたら、ゾンビを残さず誤送信も防ぐため所有権を手放す。
    /// 観測できなかった場合は占有中のまま扱う。プロセスが残っているのに解放すると停止手段を失う。
    public func isOccupyingResources() -> Bool {
        if isRunning { return true }
        guard let processGroupID = launchedProcessGroupID else { return false }
        // 所有権を失った PGID は再利用されうる。自分の占有として主張しない。
        guard let child, child.snapshot.ownsProcessGroup else {
            releaseOwnershipWithoutSignal()
            return false
        }

        switch groupStateProbe(processGroupID).hasLiveMembers {
        case true?:
            return true
        case nil:
            noteGroupStateUnavailable(processGroupID)
            return true
        case false?:
            releaseProcessGroupOwnership()
            return false
        }
    }

    /// リーダーを回収して所有権を手放す。回収できなければ所有権を保持したままにする。
    private func releaseProcessGroupOwnership() {
        guard let child else {
            launchedProcessGroupID = nil
            return
        }
        if child.release() {
            launchedProcessGroupID = nil
        }
    }

    /// 観測できないことを黙って握りつぶさず、警告として画面へ流す。
    private func noteGroupStateUnavailable(_ processGroupID: pid_t) {
        guard case let .unavailable(code) = groupStateProbe(processGroupID) else { return }
        let message = "プロセスグループ \(processGroupID) の状態を取得できませんでした"
            + "（errno \(code): \(CStringDecoding.errorMessage(code))）。"
            + "残っている可能性があるため占有中として扱います。"
        guard lastWarning != message else { return }
        lastWarning = message
        continuation?.yield(.warning(message))
    }

    public func start(environment: [String: String]) async throws -> AsyncStream<Event> {
        if isRunning {
            throw RuntimeError.alreadyRunning(service: serviceName)
        }

        let spawned = try ProcessRunner.spawn(
            command,
            environment: environment,
            output: .files(
                standardOutput: logFiles.standardOutput,
                standardError: logFiles.standardError
            )
        )
        let process = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)

        // 同一性の観測より先に記録する。以降のどの経路でも、起動したグループを
        // 見失って停止できなくなることがないようにするため。
        child = process
        launchedProcessGroupID = spawned.processGroupID
        didExit = false
        stopRequested = false
        exitRecord = nil
        lastWarning = nil
        runtime = nil

        let identity = try await observeIdentity(of: spawned, process: process)

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            of: Event.self,
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation

        // ログは受信順のまま continuation へ流す。actor を挟むと順序が崩れるため直接 yield する。
        tail = LogFileTail(
            files: [
                (url: logFiles.standardOutput, stream: .stdout),
                (url: logFiles.standardError, stream: .stderr),
            ],
            label: serviceID.uuidString,
            onBatch: { lines in
                continuation.yield(.log(lines))
            }
        )

        if let identity {
            let observed = ObservedRuntime(
                serviceID: serviceID,
                identity: identity,
                processGroupID: spawned.processGroupID,
                observedPorts: [],
                startedAt: identity.startedAt,
                management: .childProcess
            )
            runtime = observed
            continuation.yield(.started(observed))
            startPortPolling(processGroupID: spawned.processGroupID)
        }

        exitTask = Task { [weak self] in
            let status = await process.waitForExit(timeout: nil) ?? .unknown
            await self?.childDidExit(status)
        }

        return stream
    }

    /// 動作中の親を同定できない場合は安全に管理できないため、起動を取り消す。
    /// 観測前に親が終了した場合は、予約済みPGIDだけで残った孫を管理する。
    private func observeIdentity(
        of spawned: SpawnedProcess,
        process: ChildProcess
    ) async throws -> ProcessIdentity? {
        let deadline = ContinuousClock.now + Self.identityObservationWindow
        while true {
            if let identity = identityProbe(spawned.pid, command.workingDirectory) {
                return identity
            }
            if process.currentStatus != nil { return nil }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.currentStatus != nil { return nil }

        stopRequested = true
        guard sendOwnedSignal(SIGTERM) else {
            throw RuntimeError.ownershipLost(service: serviceName)
        }
        // UIが停止手段を出せるよう、取消後の残存PGIDをエラーに含める。
        let drained = await waitForGroupToDrain(
            processGroupID: spawned.processGroupID,
            timeout: Self.minimumDrainWindow
        )
        if drained {
            releaseProcessGroupOwnership()
        }
        throw RuntimeError.identityUnavailable(
            service: serviceName,
            pid: spawned.pid,
            residualProcessGroupID: drained ? nil : spawned.processGroupID
        )
    }

    public func stop(grace: Duration = .seconds(10)) async throws -> StopOutcome {
        guard let child, let processGroupID = launchedProcessGroupID else {
            throw RuntimeError.notRunning(service: serviceName)
        }

        if let exit = observedExit {
            let status = exit.status
            // 未回収のリーダーがPGIDを予約しているため、残った孫へ安全に送信できる。
            // 観測できなかった場合は「居ない」と決めつけず、通常終了を送って確かめる。
            if groupStateProbe(processGroupID).hasLiveMembers == false {
                releaseProcessGroupOwnership()
                return .exited(status)
            }
            stopRequested = true
            guard sendOwnedSignal(SIGTERM) else { return .ownershipLost }
            return await outcome(
                after: status,
                processGroupID: processGroupID,
                drainTimeout: grace
            )
        }

        // runtimeがない経路では、未回収のリーダーがPIDとPGIDの再利用を防いでいる。
        if let runtime {
            guard startAbstimeProbe(runtime.identity.pid).value == runtime.identity.startAbstime else {
                throw RuntimeError.identityMismatch(
                    service: serviceName,
                    pid: runtime.identity.pid
                )
            }
        }

        stopRequested = true
        let deadline = ContinuousClock.now + grace
        guard sendOwnedSignal(SIGTERM) else { return .ownershipLost }

        guard let status = await child.waitForExit(timeout: grace) else {
            return .residual(processGroupID: processGroupID)
        }
        return await outcome(
            after: status,
            processGroupID: processGroupID,
            drainTimeout: deadline - ContinuousClock.now
        )
    }

    private func outcome(
        after status: ExitStatus,
        processGroupID: pid_t,
        drainTimeout: Duration
    ) async -> StopOutcome {
        let drained = await waitForGroupToDrain(
            processGroupID: processGroupID,
            timeout: max(drainTimeout, Self.minimumDrainWindow)
        )
        guard drained else { return .residual(processGroupID: processGroupID) }
        releaseProcessGroupOwnership()
        return .exited(status)
    }

    /// 所有している PGID にだけシグナルを送る。
    ///
    /// 未回収のリーダー（ゾンビ）が PID を予約している間だけ、この PGID は
    /// 再利用されない。所有権を失っていたら PGID は別のグループを指しうるので、
    /// 送らずに所有権の記録も落とす。以後どの経路からも送れなくなる。
    ///
    /// 送出の失敗では操作を中断しない。停止できたかどうかは、最終的に
    /// 「動いているプロセスが残っているか」で判断する。送出直前に最後のメンバーが
    /// 終了してゾンビだけになると EPERM になるなど、失敗しても停止できている場合があるため。
    /// ただし黙って捨てず、警告として画面へ流す。
    @discardableResult
    private func sendOwnedSignal(_ signal: Int32) -> Bool {
        guard let processGroupID = launchedProcessGroupID else { return false }
        guard let child, child.snapshot.ownsProcessGroup else {
            releaseOwnershipWithoutSignal()
            return false
        }

        guard signalSender(processGroupID, signal) != 0 else { return true }
        let code = errno
        // 既に誰も居ないグループへの送信は警告にもしない。
        guard code != ESRCH else { return true }

        let message = "プロセスグループ \(processGroupID) へシグナル \(signal) を送れませんでした"
            + "（errno \(code): \(CStringDecoding.errorMessage(code))）。"
        if lastWarning != message {
            lastWarning = message
            continuation?.yield(.warning(message))
        }
        return true
    }

    /// 所有権を失った PGID は二度と参照しない。
    /// 記録を残すと、占有判定や手掛かりの保存が別グループを指すことになる。
    private func releaseOwnershipWithoutSignal() {
        guard launchedProcessGroupID != nil else { return }
        launchedProcessGroupID = nil
        let message = "プロセスグループの所有権を失ったため、停止操作を行いません。"
            + "別のプロセスへシグナルを送らないためです。"
        guard lastWarning != message else { return }
        lastWarning = message
        continuation?.yield(.warning(message))
    }

    private static let minimumDrainWindow: Duration = .seconds(1)

    private static let identityObservationWindow: Duration = .milliseconds(200)

    /// 所有権維持のためのゾンビは資源を握らないので、解放待ちの対象に含めない。
    /// 観測できない間は解放と判定しない。判定できないまま猶予が切れたら残存として扱う。
    private func waitForGroupToDrain(processGroupID: pid_t, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isDrained(processGroupID) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isDrained(processGroupID)
    }

    private func isDrained(_ processGroupID: pid_t) -> Bool {
        switch groupStateProbe(processGroupID).hasLiveMembers {
        case false?:
            return true
        case nil:
            noteGroupStateUnavailable(processGroupID)
            return false
        case true?:
            return false
        }
    }

    /// 強制終了（SIGKILL）。利用者の明示的な確認を経てから呼ぶこと。
    public func forceStop(grace: Duration = .seconds(5)) async throws -> StopOutcome {
        guard let child, let processGroupID = launchedProcessGroupID else {
            throw RuntimeError.notRunning(service: serviceName)
        }

        if child.currentStatus == nil, let runtime {
            guard startAbstimeProbe(runtime.identity.pid).value == runtime.identity.startAbstime else {
                throw RuntimeError.identityMismatch(
                    service: serviceName,
                    pid: runtime.identity.pid
                )
            }
        }
        stopRequested = true
        guard sendOwnedSignal(SIGKILL) else { return .ownershipLost }

        let deadline = ContinuousClock.now + grace
        let status = await child.waitForExit(timeout: grace)
        return await outcome(
            after: status ?? .unknown,
            processGroupID: processGroupID,
            drainTimeout: deadline - ContinuousClock.now
        )
    }

    /// 現在のプロセスグループから、再検証用の証拠を作る。
    ///
    /// 起動した子は未回収のゾンビが PID を予約しているため、この時点で PGID が
    /// 再利用されていないことが保証されている。よってここで測った錨は信用してよい。
    /// 取得できない場合は退避せず nil を返す。
    public func captureGroupEvidence() -> ProcessGroupEvidence? {
        guard let processGroupID = launchedProcessGroupID else { return nil }
        guard let child, child.snapshot.ownsProcessGroup else {
            releaseOwnershipWithoutSignal()
            return nil
        }
        return ProcessGroupIdentification.captureEvidence(
            processGroupID: processGroupID,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        )
    }

    /// ポートを今すぐ実測し直す。
    ///
    /// 定期ポーリングの間隔ぶん古い値で切替のゲートを判定すると、
    /// 直前に増えた listen を見落とす。停止前に必ずここを通す。
    /// 観測に失敗した場合は握りつぶさず送出する。「ポートなし」と扱ってはいけない。
    public func refreshPorts() async throws {
        guard let processGroupID = launchedProcessGroupID else { return }
        let ports: [ObservedPort]
        do {
            ports = try await portProbe(processGroupID)
                .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
        } catch {
            // 実測できなかったことを「0件」と混同しない。
            portRecord = .unavailable
            let message = "\(error)"
            if lastWarning != message {
                lastWarning = message
                continuation?.yield(.warning(message))
            }
            throw error
        }
        portRecord = .observed(ports.map(\.port))
        guard var runtime else { return }
        guard runtime.observedPorts != ports else { return }
        runtime.observedPorts = ports
        self.runtime = runtime
        continuation?.yield(.ports(ports))
    }

    private func startPortPolling(processGroupID: pid_t) {
        portTask?.cancel()
        portTask = Task { [weak self, portPollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollPorts(processGroupID: processGroupID)
                do {
                    try await Task.sleep(for: portPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func pollPorts(processGroupID: pid_t) async {
        do {
            let ports = try await portProbe(processGroupID)
                .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            portRecord = .observed(ports.map(\.port))
            guard var runtime else { return }
            guard runtime.observedPorts != ports else { return }
            runtime.observedPorts = ports
            self.runtime = runtime
            continuation?.yield(.ports(ports))
        } catch {
            // 実測に失敗しても「ポートなし」とは扱わない。警告として表示へ回す。
            portRecord = .unavailable
            let message = "\(error)"
            guard lastWarning != message else { return }
            lastWarning = message
            continuation?.yield(.warning(message))
        }
    }

    private func childDidExit(_ status: ExitStatus) {
        guard !didExit else { return }
        didExit = true
        let exit = recordExit(status)
        portTask?.cancel()
        portTask = nil
        tail?.drain()
        continuation?.yield(
            .exited(
                status: exit.status,
                requestedByUser: exit.requestedByUser,
                startupConfirmed: false
            )
        )

        // 終了直前に書き出された分を取りこぼさないよう、少し待ってから読み切って閉じる。
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.finishStream()
        }
    }

    private func finishStream() {
        // cancel() が残りを読み切って onBatch へ流すため、finish より先に呼ぶ。
        tail?.cancel()
        tail = nil
        continuation?.finish()
        continuation = nil
    }
}
