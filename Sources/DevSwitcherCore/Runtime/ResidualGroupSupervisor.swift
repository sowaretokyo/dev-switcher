import Darwin
import Foundation

/// 起動したプロセスは終了したが、プロセスグループに残りがある状態の停止を担う。
///
/// リーダーが居ないので同一性で守れない。代わりに `ProcessGroupIdentification` の
/// 錨照合とシグナル送出を、分離できない同期APIで毎回評価する。
///
/// 同定できた時点では、いま同じグループに居るメンバー全員が自分の子孫だと確認できる。
/// そのたびに証拠を更新して後発の子孫を錨へ加える。これをしないと、
/// SIGTERM で古い錨のプロセスだけが終了したあと、残ったプロセスを同定できなくなり
/// SIGKILL を送れなくなる。
///
/// 引き継ぎ（adopt）は提供しない。管理できないものを「稼働中」として扱わないため。
actor ResidualGroupSupervisor {
    typealias PortProbe = @Sendable (pid_t) async throws -> [ObservedPort]
    private let processGroupIdentifier: pid_t
    private var evidence: ProcessGroupEvidence
    private let groupStateProbe: ProcessGroupIdentification.GroupStateProbe
    private let startAbstimeProbe: ProcessGroupIdentification.StartAbstimeProbe
    private let bootSessionProbe: ProcessGroupIdentification.BootSessionProbe
    private let signalSender: ProcessGroupIdentification.SignalSender
    private let portProbe: PortProbe
    private var released = false
    /// 実測した listen ポート。何を握られているのか画面へ出すために保持する。
    private var ports: ObservedPortRecord = .unavailable
    private var portDetails: [ObservedPort] = []

    init(
        processGroupID: pid_t,
        evidence: ProcessGroupEvidence,
        groupStateProbe: @escaping ProcessGroupIdentification.GroupStateProbe = {
            ProcessInspector.processGroupState($0)
        },
        startAbstimeProbe: @escaping ProcessGroupIdentification.StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping ProcessGroupIdentification.BootSessionProbe = {
            ProcessInspector.bootSessionID()
        },
        signalSender: @escaping ProcessGroupIdentification.SignalSender = { kill(-$0, $1) },
        portProbe: @escaping PortProbe = { processGroupID in
            try await PortInspector.listeningPorts(processGroupID: processGroupID)
        }
    ) {
        self.processGroupIdentifier = processGroupID
        self.evidence = evidence
        self.groupStateProbe = groupStateProbe
        self.startAbstimeProbe = startAbstimeProbe
        self.bootSessionProbe = bootSessionProbe
        self.signalSender = signalSender
        self.portProbe = portProbe
    }

    public var processGroupID: pid_t? { released ? nil : processGroupIdentifier }

    public var observedPorts: ObservedPortRecord { released ? .observed([]) : ports }
    public var observedPortDetails: [ObservedPort] { released ? [] : portDetails }

    /// ポートを実測し直す。何を握られているのかが分からないと、利用者は判断できない。
    /// 失敗は「ポートなし」ではなく「不明」として残す。
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

    /// 同定し、成功したら証拠を更新する。
    @discardableResult
    public func identify() -> ProcessGroupIdentification.Result {
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

    public func stop(grace: Duration = .seconds(10)) async -> ServiceStopOutcome {
        await terminate(signal: SIGTERM, grace: grace)
    }

    /// 強制終了。利用者が対象を確認して明示的に選んだときにだけ呼ぶ。
    public func forceStop(grace: Duration = .seconds(5)) async -> ServiceStopOutcome {
        await terminate(signal: SIGKILL, grace: grace)
    }

    private func terminate(signal: Int32, grace: Duration) async -> ServiceStopOutcome {
        guard !released else { return .stopped(nil) }

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
                reason: "プロセスグループ \(processGroupIdentifier) を前回のものと同定できませんでした。"
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

        // 猶予の間も、同定できている間は証拠を更新し続ける。
        // ここで更新しておかないと、古い錨のプロセスだけが終了したあとに
        // 残ったプロセスを同定できず、強制終了へ進めなくなる。
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if case .empty = identify() {
                released = true
                return .stopped(nil)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if case .empty = identify() {
            released = true
            return .stopped(nil)
        }
        return .residual(
            processGroupID: processGroupIdentifier,
            reason: "猶予内にプロセスグループが空になりませんでした。"
        )
    }
}
