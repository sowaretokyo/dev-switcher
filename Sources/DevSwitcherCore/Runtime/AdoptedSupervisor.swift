import Darwin
import Foundation

/// アプリ再起動後に引き継いだプロセスの管理。
///
/// `ServiceSupervisor` と違い、対象は自分の子ではない。`waitpid` で回収できないため、
/// ゾンビによる PID・PGID の予約が効かない。よって停止の直前に必ず同一性を実測し、
/// 一致したときだけシグナルを送る。一致しなければ「止められなかった」として返し、
/// 別プロセスへ送らない。
///
/// リーダーが終了したあとも孫プロセスがグループに残ることがある。このとき PGID は
/// 再利用されうるので、「同じ PGID に誰か居る」だけでは自分の資源とは言えない。
/// 記録済みの具体的なプロセス（PID＋開始 abstime）が残っているかで同定する。
/// 同定できた時点で証拠を更新し、後発の子孫も錨へ加える。
///
/// 前回起動時に標準出力・標準エラーを接続したログファイルの追尾を再開する。
actor AdoptedSupervisor {
    typealias PortProbe = @Sendable (pid_t) async throws -> [ObservedPort]

    let serviceID: UUID
    let serviceName: String

    private let identity: ProcessIdentity
    private let processGroupIdentifier: pid_t
    private var ports: ObservedPortRecord
    private var portDetails: [ObservedPort]
    private var evidence: ProcessGroupEvidence
    private let startAbstimeProbe: ProcessGroupIdentification.StartAbstimeProbe
    private let groupStateProbe: ProcessGroupIdentification.GroupStateProbe
    private let bootSessionProbe: ProcessGroupIdentification.BootSessionProbe
    private let signalSender: ProcessGroupIdentification.SignalSender
    private let portProbe: PortProbe
    /// 停止を試みて所有権を手放したか。手放した PGID へは二度と送らない。
    private var released = false
    private var logTail: LogFileTail?

    init(
        serviceID: UUID,
        serviceName: String,
        identity: ProcessIdentity,
        processGroupID: pid_t,
        observedPorts: [ObservedPort],
        evidence: ProcessGroupEvidence,
        startAbstimeProbe: @escaping ProcessGroupIdentification.StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        groupStateProbe: @escaping ProcessGroupIdentification.GroupStateProbe = {
            ProcessInspector.processGroupState($0)
        },
        bootSessionProbe: @escaping ProcessGroupIdentification.BootSessionProbe = {
            ProcessInspector.bootSessionID()
        },
        signalSender: @escaping ProcessGroupIdentification.SignalSender = { kill(-$0, $1) },
        portProbe: @escaping PortProbe = { processGroupID in
            try await PortInspector.listeningPorts(processGroupID: processGroupID)
        }
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.identity = identity
        self.processGroupIdentifier = processGroupID
        let sortedPorts = observedPorts.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
        self.portDetails = sortedPorts
        self.ports = .observed(sortedPorts.map(\.port))
        self.evidence = evidence
        self.startAbstimeProbe = startAbstimeProbe
        self.groupStateProbe = groupStateProbe
        self.bootSessionProbe = bootSessionProbe
        self.signalSender = signalSender
        self.portProbe = portProbe
    }

    public var processGroupID: pid_t? { released ? nil : processGroupIdentifier }

    public var observedPorts: ObservedPortRecord { ports }

    func resumeLogs(
        files: ServiceLogFiles,
        events: @escaping @Sendable (ServiceSupervisor.Event) -> Void
    ) throws {
        guard !released else { throw RuntimeError.notRunning(service: serviceName) }
        precondition(logTail == nil, "引き継いだプロセスのログ追尾を二重に開始できません。")
        logTail = try LogFileTail(
            files: [
                (url: files.standardOutput, stream: .stdout),
                (url: files.standardError, stream: .stderr),
            ],
            label: serviceID.uuidString,
            onBatch: { events(.log($0)) },
            onFailure: { events(.logUnavailable("\($0)")) }
        )
    }

    public var observedRuntime: ObservedRuntime? {
        guard !released else { return nil }
        return ObservedRuntime(
            serviceID: serviceID,
            identity: identity,
            processGroupID: processGroupIdentifier,
            observedPorts: portDetails,
            startedAt: identity.startedAt,
            management: .adopted
        )
    }

    /// 引き継いだ本体（プロセスグループのリーダー）が同じプロセスとして生きているか。
    public func isRunning() -> Bool {
        guard !released else { return false }
        return matchesIdentity()
    }

    /// リーダーが終了していても、同定できる子孫が残っていれば資源を握りうる。
    public func isOccupyingResources() -> Bool {
        guard !released else { return false }
        if matchesIdentity() { return true }

        switch identifyGroup() {
        case .matched: return true
        case .empty: return false
        // 同定できないものを自分の占有として主張しない。無関係なプロセスを
        // 巻き込む停止操作の入口になるため。
        case .notIdentified: return false
        // 観測できない間は「居ない」と決めつけない。
        case .unobservable: return true
        }
    }

    /// リーダーを見失ったあとのプロセスグループの同定。成功したら証拠を更新する。
    @discardableResult
    public func identifyGroup() -> ProcessGroupIdentification.Result {
        let result = ProcessGroupIdentification.identify(
            processGroupID: processGroupIdentifier,
            evidence: evidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        )
        if let refreshed = result.evidence {
            evidence = refreshed
        }
        return result
    }

    /// 失敗は「ポートなし」ではなく「不明」として残す。
    /// 空配列と混同すると、次回に「ポートを持たないサービス」として照合なしで引き継いでしまう。
    public func refreshPorts() async throws {
        guard !released else { return }
        do {
            let measured = try await portProbe(processGroupIdentifier)
                .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            portDetails = measured
            ports = .observed(measured.map(\.port))
        } catch {
            portDetails = []
            ports = .unavailable
            throw error
        }
    }

    public func stop(grace: Duration = .seconds(10)) async -> ServiceStopOutcome {
        await terminate(signal: SIGTERM, grace: grace)
    }

    /// 強制終了。利用者が対象を確認して明示的に選んだときにだけ呼ぶ。
    public func forceStop(grace: Duration = .seconds(5)) async -> ServiceStopOutcome {
        await terminate(signal: SIGKILL, grace: grace)
    }

    private func terminate(signal: Int32, grace: Duration) async -> ServiceStopOutcome {
        guard !released else { return .stopped(nil) }
        defer {
            if released {
                logTail?.cancel()
                logTail = nil
            }
        }

        // 検証結果を保持して後から使わず、所属の最終観測から送出までを1 APIで行う。
        switch ProcessGroupIdentification.identifyAndSend(
            signal,
            processGroupID: processGroupIdentifier,
            evidence: evidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe,
            sender: signalSender
        ) {
        case .empty, .notPresent:
            released = true
            return .stopped(nil)
        case let .sent(refreshedEvidence):
            evidence = refreshedEvidence
        case let .notIdentified(reason):
            return .residual(
                processGroupID: processGroupIdentifier,
                reason: "プロセスグループ \(processGroupIdentifier) を"
                    + "引き継ぎ時のものと同定できませんでした。"
                    + "別のプロセスへシグナルを送らないため、停止操作を行いませんでした。\n\(reason)"
            )
        case let .unobservable(reason):
            return .residual(
                processGroupID: processGroupIdentifier,
                reason: "\(reason)同定できないため停止操作を行いませんでした。"
            )
        case let .failed(code):
            return .residual(
                processGroupID: processGroupIdentifier,
                reason: "シグナルを送れませんでした（errno \(code): "
                    + "\(CStringDecoding.errorMessage(code))）。"
            )
        }

        // 猶予の間も証拠を更新し続ける。古い錨のプロセスだけが終了したあとに
        // 残りを同定できなくなると、強制終了へ進めなくなる。
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if isDrained() {
                released = true
                return .stopped(nil)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isDrained() {
            released = true
            return .stopped(nil)
        }
        return .residual(
            processGroupID: processGroupIdentifier,
            reason: "猶予内にプロセスグループが空になりませんでした。"
        )
    }

    /// PID の再利用を boot 内の開始 abstime で検出する。
    /// `exec` で実行ファイルが変わっても開始時刻は変わらない。
    private func matchesIdentity() -> Bool {
        guard case let .present(startAbstime) = startAbstimeProbe(identity.pid) else { return false }
        return startAbstime == identity.startAbstime
    }

    private func isDrained() -> Bool {
        // 証拠の更新も兼ねる。まだ子孫が残っていれば錨を最新にしておく。
        switch identifyGroup() {
        case .empty: true
        // 同定できない・観測できない間は解放と判定しない。
        case .matched, .notIdentified, .unobservable: false
        }
    }
}
