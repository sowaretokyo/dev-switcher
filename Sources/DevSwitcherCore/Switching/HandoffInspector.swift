import Darwin
import Foundation

/// 引き継ぎ候補。実測で照合できたものだけがここに入る。
/// `RuntimeHint` の保存値をそのまま状態として復元しないため、実測した値を別に持つ。
public struct HandoffCandidate: Equatable, Sendable, Identifiable {
    public let hint: RuntimeHint
    /// 実測し直した同一性。保存値ではない。
    public let identity: ProcessIdentity
    /// 実測し直したプロセスグループの証拠。
    public let evidence: ProcessGroupEvidence
    /// 実測し直した listen ポート。
    public let observedPorts: [ObservedPort]

    public var id: UUID { hint.serviceID }

    init(
        hint: RuntimeHint,
        identity: ProcessIdentity,
        evidence: ProcessGroupEvidence,
        observedPorts: [ObservedPort]
    ) {
        self.hint = hint
        self.identity = identity
        self.evidence = evidence
        self.observedPorts = observedPorts
    }
}

/// 引き継ぎはできないが、停止はできるプロセス。
///
/// 起動したプロセスが残っていても期待どおりに動いていない場合や、
/// 起動プロセスは終了したのに孫プロセスがグループに残っている場合がこれにあたる。
/// 「稼働中」として引き継ぐと嘘になるが、資源を握っているので停止手段は必要になる。
public struct StoppableProcessFinding: Equatable, Sendable, Identifiable {
    /// 何を根拠に停止してよいと判断したか。停止側はこの根拠で再検証してから送信する。
    public enum Evidence: Equatable, Sendable {
        /// 起動したプロセスの同一性が一致した。錨で再検証して停止できる。
        case matchedLeader(ProcessIdentity)
        /// リーダーは終了したが、記録済みの錨を持つ子孫が残っていた。
        case verifiedGroup(livePIDs: [pid_t])
    }

    public let hint: RuntimeHint
    public let evidence: Evidence
    /// 実測し直したプロセスグループの証拠。停止側はこれで再検証する。
    public let groupEvidence: ProcessGroupEvidence
    /// 引き継がない理由。黙って落とさず画面へ出す。
    public let reason: String

    public var id: UUID { hint.serviceID }

    init(
        hint: RuntimeHint,
        evidence: Evidence,
        groupEvidence: ProcessGroupEvidence,
        reason: String
    ) {
        self.hint = hint
        self.evidence = evidence
        self.groupEvidence = groupEvidence
        self.reason = reason
    }
}

/// 候補にしなかった理由。黙って捨てず、なぜ引き継がなかったのかを画面へ出せるようにする。
public enum HandoffRejection: Equatable, Sendable, CustomStringConvertible {
    case processGone
    case anchorMismatch(expected: ProcessAnchor, actual: UInt64)
    case executableMismatch(expected: String, actual: String?)
    case workingDirectoryMismatch(expected: String, actual: String?)
    case observationFailed(String)
    /// 対応するプロジェクト／サービス定義が現在は存在しない。プロセス不存在の証明ではない。
    case definitionMissing(projectID: UUID, serviceID: UUID)
    /// リーダーが一致せず、プロセスグループも同定できなかった。記録は古いと判断できる。
    case groupNotIdentified(leaderReason: String, groupReason: String)
    /// リーダーが一致せず、プロセスグループの状態も観測できなかった。判断できない。
    case groupUnobservable(leaderReason: String, groupReason: String)
    /// 手掛かりの中身が壊れている（本体と PGID が別グループを指すなど）。
    case inconsistentHint(String)
    /// 旧形式の記録で、本体を確認できなかった。安全な錨へ変換できないので停止に使わない。
    case legacyLeaderUnverified(reason: String)

    /// 「もう存在しない」と結論づけてよいか。
    /// 観測できなかっただけのものを捨てると、残っているプロセスを見失う。
    public var isConclusive: Bool {
        switch self {
        case .processGone, .anchorMismatch, .executableMismatch,
             .workingDirectoryMismatch, .groupNotIdentified:
            true
        case .observationFailed, .definitionMissing, .groupUnobservable,
             .inconsistentHint, .legacyLeaderUnverified:
            false
        }
    }

    public var description: String {
        switch self {
        case .processGone:
            "プロセスが存在しません。"
        case let .anchorMismatch(expected, actual):
            "プロセスが一致しません（記録した PID \(expected.pid) の開始 abstime "
                + "\(expected.startAbstime) / 実測 \(actual)）。"
                + "PID が再利用された可能性があります。"
        case let .executableMismatch(expected, actual):
            "実行ファイルが一致しません（記録 \(expected) / 実測 \(actual ?? "取得できず")）。"
        case let .workingDirectoryMismatch(expected, actual):
            "作業ディレクトリが一致しません（記録 \(expected) / 実測 \(actual ?? "取得できず")）。"
        case let .observationFailed(reason):
            "実測できませんでした（\(reason)）。一致を確認できないため引き継ぎません。"
        case let .definitionMissing(projectID, serviceID):
            "対応するプロジェクトまたはサービス定義が見つかりません"
                + "（project \(projectID.uuidString) / service \(serviceID.uuidString)）。"
                + "定義が復元されるまで手掛かりを保持します。"
        case let .groupNotIdentified(leaderReason, groupReason):
            "\(leaderReason)\nプロセスグループも前回のものと同定できませんでした。\n\(groupReason)"
        case let .groupUnobservable(leaderReason, groupReason):
            "\(leaderReason)\nプロセスグループの状態を観測できませんでした。\n\(groupReason)"
        case let .inconsistentHint(reason):
            "手掛かりの内容に矛盾があります。安全に照合できないため対象にしません。\n\(reason)"
        case let .legacyLeaderUnverified(reason):
            "旧形式の記録です。安全に照合できる情報を持たないため、"
                + "本体を確認できたときにだけ引き継ぎ・停止の対象にします。\n\(reason)"
        }
    }
}

/// 対象にしなかった記録。必須値を欠いた状態を作らないよう、形式ごとに分ける。
public enum HandoffRejectionRecord: Equatable, Sendable {
    case current(hint: RuntimeHint, reason: HandoffRejection)
    case legacy(hint: LegacyRuntimeHint, reason: HandoffRejection)

    public var reason: HandoffRejection {
        switch self {
        case let .current(_, reason): reason
        case let .legacy(_, reason): reason
        }
    }

    public var serviceID: UUID {
        switch self {
        case let .current(hint, _): hint.serviceID
        case let .legacy(hint, _): hint.serviceID
        }
    }

    public var serviceName: String {
        switch self {
        case let .current(hint, _): hint.serviceName
        case let .legacy(hint, _): hint.serviceName
        }
    }

    public var processID: pid_t {
        switch self {
        case let .current(hint, _): hint.leader.pid
        case let .legacy(hint, _): hint.pid
        }
    }

    /// この記録をもう捨ててよいか。
    /// 観測できなかった・変換できなかったものは、利用者が「停止しない」を選ぶまで残す。
    public var isConclusive: Bool { reason.isConclusive }
}

public struct HandoffReview: Equatable, Sendable {
    /// 引き継げるもの。
    public let candidates: [HandoffCandidate]
    /// 引き継げないが、停止はできるもの。
    public let stoppable: [StoppableProcessFinding]
    /// どちらでもないもの。理由つきで提示する。
    public let rejected: [HandoffRejectionRecord]

    public init(
        candidates: [HandoffCandidate],
        stoppable: [StoppableProcessFinding],
        rejected: [HandoffRejectionRecord]
    ) {
        self.candidates = candidates
        self.stoppable = stoppable
        self.rejected = rejected
    }

    public var isEmpty: Bool {
        candidates.isEmpty && stoppable.isEmpty && rejected.isEmpty
    }

    public var needsDecision: Bool {
        !candidates.isEmpty || !stoppable.isEmpty || !unresolvedRejections.isEmpty
    }

    /// 観測不能・定義不足など、捨ててよいと断定できない記録だけを判断対象に残す。
    public var unresolvedRejections: [HandoffRejectionRecord] {
        rejected.filter { !$0.isConclusive }
    }
}

/// 保存した手掛かりを実プロセスと突き合わせ、一致したものだけを候補にする。
///
/// 一致条件は「記録済みの具体的なプロセス（PID＋開始 abstime）が、同じ起動セッションで
/// いまも生きているか」。作業ディレクトリや実行ファイルは補助情報であり、
/// 安全性の根拠にはしない。他のプロセスも同じ値を持ちうるため。
///
/// 引き継げないと判断したものは、資源を握っているなら停止できるかを別に評価する。
/// 観測不能など結論の出ない記録は保持し、プロセス不存在など確実に古い記録だけを整理する。
public struct HandoffInspector: Sendable {
    public typealias StartAbstimeProbe = @Sendable (pid_t) -> ProcessInspector.StartAbstimeObservation
    public typealias StartTimeProbe = @Sendable (pid_t) -> UInt64?
    public typealias ExecutablePathProbe = @Sendable (pid_t) -> String?
    public typealias WorkingDirectoryProbe = @Sendable (pid_t) -> URL?
    public typealias PortProbe = @Sendable (pid_t) async throws -> [ObservedPort]
    public typealias GroupStateProbe = @Sendable (pid_t) -> ProcessInspector.ProcessGroupState
    public typealias BootSessionProbe = @Sendable () -> String?

    private let startAbstimeProbe: StartAbstimeProbe
    private let startTimeProbe: StartTimeProbe
    private let executablePathProbe: ExecutablePathProbe
    private let workingDirectoryProbe: WorkingDirectoryProbe
    private let portProbe: PortProbe
    private let groupStateProbe: GroupStateProbe
    private let bootSessionProbe: BootSessionProbe

    public init(
        startAbstimeProbe: @escaping StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        startTimeProbe: @escaping StartTimeProbe = { ProcessInspector.startTimeMicroseconds(pid: $0) },
        executablePathProbe: @escaping ExecutablePathProbe = { ProcessInspector.executablePath(pid: $0) },
        workingDirectoryProbe: @escaping WorkingDirectoryProbe = { ProcessInspector.workingDirectory(pid: $0) },
        portProbe: @escaping PortProbe = { processGroupID in
            try await PortInspector.listeningPorts(processGroupID: processGroupID)
        },
        groupStateProbe: @escaping GroupStateProbe = { ProcessInspector.processGroupState($0) },
        bootSessionProbe: @escaping BootSessionProbe = { ProcessInspector.bootSessionID() }
    ) {
        self.startAbstimeProbe = startAbstimeProbe
        self.startTimeProbe = startTimeProbe
        self.executablePathProbe = executablePathProbe
        self.workingDirectoryProbe = workingDirectoryProbe
        self.portProbe = portProbe
        self.groupStateProbe = groupStateProbe
        self.bootSessionProbe = bootSessionProbe
    }

    public func review(_ load: RuntimeHintsLoad) async -> HandoffReview {
        var candidates: [HandoffCandidate] = []
        var stoppable: [StoppableProcessFinding] = []
        var rejected: [HandoffRejectionRecord] = []

        for hint in load.hints {
            switch await evaluate(hint) {
            case let .adoptable(candidate):
                candidates.append(candidate)
            case let .stoppableOnly(finding):
                stoppable.append(finding)
            case let .rejected(reason):
                rejected.append(.current(hint: hint, reason: reason))
            }
        }

        // 旧形式は、本体を今の実測で確認できたときにだけ安全な錨へ変換する。
        // 確認できないものからシグナルを送ってはいけない。
        for legacy in load.legacy {
            switch convert(legacy) {
            case let .converted(hint):
                switch await evaluate(hint) {
                case let .adoptable(candidate):
                    candidates.append(candidate)
                case let .stoppableOnly(finding):
                    stoppable.append(finding)
                case let .rejected(reason):
                    rejected.append(.legacy(hint: legacy, reason: reason))
                }
            case let .unverified(reason):
                rejected.append(
                    .legacy(hint: legacy, reason: .legacyLeaderUnverified(reason: reason))
                )
            }
        }

        return HandoffReview(
            candidates: candidates,
            stoppable: stoppable,
            rejected: rejected
        )
    }

    // MARK: - 旧形式の変換

    private enum LegacyConversion {
        case converted(RuntimeHint)
        case unverified(String)
    }

    /// v1 の wall-clock 開始時刻・実行ファイル・作業ディレクトリで本体を確認し、
    /// 確認できた場合にだけ、その場で安定した錨を実測して現行形式へ変換する。
    /// v1 の値そのものを錨として信用しない。
    private func convert(_ legacy: LegacyRuntimeHint) -> LegacyConversion {
        guard let startTime = startTimeProbe(legacy.pid) else {
            return .unverified("記録されたプロセス（PID \(legacy.pid)）が存在しません。")
        }
        guard startTime == legacy.startTimeMicroseconds else {
            return .unverified("PID \(legacy.pid) の開始時刻が記録と一致しません。")
        }
        guard let executablePath = executablePathProbe(legacy.pid),
              executablePath == legacy.executablePath
        else {
            return .unverified("PID \(legacy.pid) の実行ファイルが記録と一致しません。")
        }
        guard let workingDirectory = workingDirectoryProbe(legacy.pid),
              workingDirectory.standardizedFileURL.path
                == legacy.workingDirectory.standardizedFileURL.path
        else {
            return .unverified("PID \(legacy.pid) の作業ディレクトリが記録と一致しません。")
        }
        guard let leader = measureAnchor(legacy.pid) else {
            return .unverified("PID \(legacy.pid) の開始 abstime を取得できません。")
        }
        guard let evidence = ProcessGroupIdentification.captureEvidence(
            processGroupID: legacy.processGroupID,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        ) else {
            return .unverified(
                "プロセスグループ \(legacy.processGroupID) の錨を実測できません。"
            )
        }

        return .converted(
            RuntimeHint(
                projectID: legacy.projectID,
                serviceID: legacy.serviceID,
                serviceName: legacy.serviceName,
                processGroupID: legacy.processGroupID,
                leader: leader,
                groupEvidence: evidence,
                executablePath: executablePath,
                workingDirectory: workingDirectory,
                observedPorts: .observed(legacy.observedPorts)
            )
        )
    }

    // MARK: - 現行形式の評価

    private enum Evaluation {
        case adoptable(HandoffCandidate)
        case stoppableOnly(StoppableProcessFinding)
        case rejected(HandoffRejection)
    }

    private func evaluate(_ hint: RuntimeHint) async -> Evaluation {
        // 本体と PGID の結び付きを先に確かめる。ここが崩れた手掛かりを通すと、
        // 無関係な leader と PGID を組み合わせて別グループへシグナルを送れてしまう。
        if let inconsistency = structuralProblem(of: hint) {
            return .rejected(.inconsistentHint(inconsistency))
        }
        switch matchLeader(hint) {
        case let .matched(identity, evidence):
            return await evaluatePorts(hint, identity: identity, evidence: evidence)
        case let .mismatched(rejection):
            // リーダーが一致しないだけで諦めない。孫プロセスが残っていることがある。
            return evaluateGroup(hint, leaderRejection: rejection)
        }
    }

    /// 手掛かり自体の整合性。
    ///
    /// 起動したプロセスはプロセスグループのリーダーとして起動するので、
    /// PID と PGID は必ず一致する。ここが食い違う手掛かりは、本体と無関係な
    /// プロセスグループを組み合わせられる状態であり、そのまま照合してはいけない。
    ///
    /// 「錨に本体が含まれること」は要求しない。本体が終了したあとに記録した場合、
    /// 生存メンバーだけを錨にするので本体は入らない。そこを必須にすると、
    /// まさに回収したい残存グループを一つも扱えなくなる。
    private func structuralProblem(of hint: RuntimeHint) -> String? {
        guard hint.leader.pid == hint.processGroupID else {
            return "本体（PID \(hint.leader.pid)）とプロセスグループ "
                + "\(hint.processGroupID) が一致しません。"
                + "起動したプロセスは必ずグループのリーダーになるため、この組み合わせは成立しません。"
        }
        guard !hint.groupEvidence.anchors.isEmpty else {
            return "同定に使える錨が記録されていません。"
        }
        return nil
    }

    private enum LeaderMatch {
        case matched(ProcessIdentity, ProcessGroupEvidence)
        case mismatched(HandoffRejection)
    }

    /// 記録した錨で本体を同定する。時刻の範囲や cwd は根拠にしない。
    private func matchLeader(_ hint: RuntimeHint) -> LeaderMatch {
        // 起動セッションが違えば mach absolute time の比較自体が無意味。
        guard let bootSessionID = bootSessionProbe() else {
            return .mismatched(.observationFailed("起動セッションの識別子を取得できません。"))
        }
        guard bootSessionID == hint.groupEvidence.bootSessionID else {
            return .mismatched(.processGone)
        }

        let measured: UInt64
        switch startAbstimeProbe(hint.leader.pid) {
        case let .present(value):
            measured = value
        case .notPresent:
            return .mismatched(.processGone)
        case let .unavailable(code):
            return .mismatched(
                .observationFailed(
                    "PID \(hint.leader.pid) の開始時刻を取得できませんでした"
                        + "（errno \(code): \(CStringDecoding.errorMessage(code))）。"
                )
            )
        }
        guard measured == hint.leader.startAbstime else {
            return .mismatched(.anchorMismatch(expected: hint.leader, actual: measured))
        }

        // ここから先は補助情報の確認。一致しなければ引き継がないが、
        // 同一性そのものは錨で確定しているので停止はできる。
        let executablePath = executablePathProbe(hint.leader.pid)
        guard let executablePath, executablePath == hint.executablePath else {
            return .mismatched(
                .executableMismatch(expected: hint.executablePath, actual: executablePath)
            )
        }
        let workingDirectory = workingDirectoryProbe(hint.leader.pid)
        guard let workingDirectory,
              workingDirectory.standardizedFileURL.path
                == hint.workingDirectory.standardizedFileURL.path
        else {
            return .mismatched(
                .workingDirectoryMismatch(
                    expected: hint.workingDirectory.path,
                    actual: workingDirectory?.path
                )
            )
        }

        guard let startTime = startTimeProbe(hint.leader.pid) else {
            return .mismatched(.observationFailed("開始時刻を取得できません。"))
        }
        let identity = ProcessIdentity(
            pid: hint.leader.pid,
            startAbstime: measured,
            startedAt: Date(timeIntervalSince1970: Double(startTime) / 1_000_000),
            executablePath: executablePath,
            workingDirectory: workingDirectory
        )

        // 本体が生きているので、いまのメンバーから証拠を作り直せる。
        guard let evidence = ProcessGroupIdentification.captureEvidence(
            processGroupID: hint.processGroupID,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        ) else {
            return .mismatched(.observationFailed("プロセスグループの錨を実測できません。"))
        }
        guard evidence.anchors.contains(identity.anchor) else {
            return .mismatched(
                .observationFailed(
                    "本体 PID \(identity.pid) が対象のプロセスグループに属することを確認できません。"
                )
            )
        }
        return .matched(identity, evidence)
    }

    /// 本体が一致したうえで、期待するポートを listen しているかを見る。
    /// 一致しない場合、引き継ぎはしないが本体の同一性は確かなので停止はできる。
    private func evaluatePorts(
        _ hint: RuntimeHint,
        identity: ProcessIdentity,
        evidence: ProcessGroupEvidence
    ) async -> Evaluation {
        let observedPorts: [ObservedPort]
        do {
            observedPorts = try await portProbe(hint.processGroupID)
        } catch {
            return .stoppableOnly(
                StoppableProcessFinding(
                    hint: hint,
                    evidence: .matchedLeader(identity),
                    groupEvidence: evidence,
                    reason: "listen ポートを実測できませんでした（\(error)）。"
                        + "期待どおり動いているか確認できないため引き継ぎません。"
                )
            )
        }

        // 実測できていない記録は引き継がない。空配列と混同すると、
        // 「ポートを持たないサービス」として照合なしで引き継いでしまう。
        guard case let .observed(recordedPorts) = hint.observedPorts else {
            return .stoppableOnly(
                StoppableProcessFinding(
                    hint: hint,
                    evidence: .matchedLeader(identity),
                    groupEvidence: evidence,
                    reason: "前回の listen ポートを実測できていません。"
                        + "期待どおり動いているか確認できないため引き継ぎません。"
                )
            )
        }

        // ポートを持たないサービスは、この照合を行わない（期待値が空なら一致とみなす）。
        let expectedPorts = Set(recordedPorts)
        let actualPorts = Set(observedPorts.map(\.port))
        guard expectedPorts.isSubset(of: actualPorts) else {
            return .stoppableOnly(
                StoppableProcessFinding(
                    hint: hint,
                    evidence: .matchedLeader(identity),
                    groupEvidence: evidence,
                    reason: "listen ポートが一致しません"
                        + "（記録 \(expectedPorts.sorted().map(String.init).joined(separator: ", "))"
                        + " / 実測 \(actualPorts.sorted().map(String.init).joined(separator: ", "))）。"
                )
            )
        }

        return .adoptable(
            HandoffCandidate(
                hint: hint,
                identity: identity,
                evidence: evidence,
                observedPorts: observedPorts.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            )
        )
    }

    /// 本体が一致しなかったとき、プロセスグループに残りが居ないかを見る。
    /// 記録済みの錨を持つメンバーが残っている場合だけ停止対象として提示する。
    private func evaluateGroup(
        _ hint: RuntimeHint,
        leaderRejection: HandoffRejection
    ) -> Evaluation {
        let result = ProcessGroupIdentification.identify(
            processGroupID: hint.processGroupID,
            evidence: hint.groupEvidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        )

        switch result {
        case let .matched(evidence):
            let livePIDs = evidence.anchors.map(\.pid).sorted()
            return .stoppableOnly(
                StoppableProcessFinding(
                    hint: hint,
                    evidence: .verifiedGroup(livePIDs: livePIDs),
                    groupEvidence: evidence,
                    reason: "起動したプロセス（PID \(hint.leader.pid)）は終了していますが、"
                        + "プロセスグループ \(hint.processGroupID) に "
                        + "\(livePIDs.map(String.init).joined(separator: ", ")) が残っています。"
                        + "管理できる本体が無いため引き継げません。"
                )
            )
        case .empty:
            return .rejected(leaderRejection)
        case let .notIdentified(reason):
            return .rejected(
                .groupNotIdentified(
                    leaderReason: leaderRejection.description,
                    groupReason: reason
                )
            )
        case let .unobservable(reason):
            // 観測できなかっただけ。捨ててよいとは判断しない。
            return .rejected(
                .groupUnobservable(
                    leaderReason: leaderRejection.description,
                    groupReason: reason
                )
            )
        }
    }

    private func measureAnchor(_ pid: pid_t) -> ProcessAnchor? {
        guard case let .present(startAbstime) = startAbstimeProbe(pid) else { return nil }
        return ProcessAnchor(pid: pid, startAbstime: startAbstime)
    }
}
