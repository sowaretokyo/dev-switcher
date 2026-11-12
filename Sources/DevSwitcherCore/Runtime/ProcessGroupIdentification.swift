import Darwin
import Foundation

/// プロセスグループが「前回 Dev Switcher が管理していたものか」を判定する。
///
/// POSIX には所属の観測と `kill` をatomicに行うAPIがない。そのため絶対的な保証ではなく、
/// シグナル送出の直前まで具体的なプロセス錨を繰り返し照合し、判断できない場合は
/// fail-closedにする。検証結果を保存して後から送れるtokenは外へ返さない。
enum ProcessGroupIdentification {
    enum Result: Equatable, Sendable {
        case matched(ProcessGroupEvidence)
        case empty
        case notIdentified(reason: String)
        case unobservable(reason: String)

        var evidence: ProcessGroupEvidence? {
            guard case let .matched(evidence) = self else { return nil }
            return evidence
        }
    }

    enum SignalOutcome: Equatable, Sendable {
        case sent(evidence: ProcessGroupEvidence)
        case notPresent
        case empty
        case notIdentified(reason: String)
        case unobservable(reason: String)
        case failed(errno: Int32)

        var failureReason: String? {
            switch self {
            case let .notIdentified(reason), let .unobservable(reason):
                reason
            case let .failed(code):
                L10n.text("シグナルを送れませんでした（errno \(code): \(CStringDecoding.errorMessage(code))）。")
            case .sent, .notPresent, .empty:
                nil
            }
        }
    }

    typealias GroupStateProbe = @Sendable (pid_t) -> ProcessInspector.ProcessGroupState
    typealias StartAbstimeProbe = @Sendable (pid_t) -> ProcessInspector.StartAbstimeObservation
    typealias BootSessionProbe = @Sendable () -> String?
    typealias SignalSender = @Sendable (pid_t, Int32) -> Int32

    static func identify(
        processGroupID: pid_t,
        evidence: ProcessGroupEvidence,
        groupStateProbe: @escaping GroupStateProbe = { ProcessInspector.processGroupState($0) },
        startAbstimeProbe: @escaping StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping BootSessionProbe = { ProcessInspector.bootSessionID() }
    ) -> Result {
        guard processGroupID > 0 else {
            return .notIdentified(reason: L10n.text("プロセスグループ ID が不正です（\(processGroupID)）。"))
        }
        guard !evidence.isEmpty else {
            return .notIdentified(reason: L10n.text("同定に使える記録がありません。"))
        }

        guard let bootSessionID = bootSessionProbe() else {
            return .unobservable(reason: L10n.text("起動セッションの識別子を取得できませんでした。"))
        }
        guard bootSessionID == evidence.bootSessionID else {
            return .notIdentified(
                reason: L10n.text("""
                    記録したときと起動セッションが違います。\
                    再起動をまたいでいるため、同じプロセスグループとは扱いません。
                    """)
            )
        }

        let firstPass: [ProcessInspector.ProcessGroupMember]
        switch liveMembers(processGroupID, probe: groupStateProbe) {
        case let .success(members): firstPass = members
        case let .failure(reason): return .unobservable(reason: reason)
        }
        guard !firstPass.isEmpty else { return .empty }

        let firstAnchors: [ProcessAnchor]
        switch observeAnchors(firstPass, probe: startAbstimeProbe) {
        case let .success(anchors): firstAnchors = anchors
        case let .failure(reason): return .unobservable(reason: reason)
        }
        let saved = Set(evidence.anchors)
        guard let matchedAnchor = firstAnchors.first(where: { saved.contains($0) }) else {
            return .notIdentified(
                reason: L10n.text("""
                    記録したプロセスが、このプロセスグループに1つも残っていません。\
                    プロセスグループ ID が再利用された可能性があるため、同一とは扱いません。
                    """)
            )
        }

        // 2回目は後発の子孫を拾う。全メンバーの錨を読めない場合、グループ全体へ
        // シグナルを送ってよいと証明できないので観測不能にする。
        let secondPass: [ProcessInspector.ProcessGroupMember]
        switch liveMembers(processGroupID, probe: groupStateProbe) {
        case let .success(members): secondPass = members
        case let .failure(reason): return .unobservable(reason: reason)
        }
        guard !secondPass.isEmpty else { return .empty }
        switch observeAnchors(secondPass, probe: startAbstimeProbe) {
        case let .success(anchors):
            guard anchors.contains(matchedAnchor) else {
                return movedAnchor(matchedAnchor)
            }
        case let .failure(reason):
            return .unobservable(reason: reason)
        }

        // 錨を読み終えたあと、所属を3回目のgroup観測で取り直す。
        // [A] → [A] → [B] の競合ではここでAが消えているため送出へ進まない。
        let thirdPass: [ProcessInspector.ProcessGroupMember]
        switch liveMembers(processGroupID, probe: groupStateProbe) {
        case let .success(members): thirdPass = members
        case let .failure(reason): return .unobservable(reason: reason)
        }
        guard !thirdPass.isEmpty else { return .empty }

        let refreshed: [ProcessAnchor]
        switch observeAnchors(thirdPass, probe: startAbstimeProbe) {
        case let .success(anchors): refreshed = anchors
        case let .failure(reason): return .unobservable(reason: reason)
        }
        guard refreshed.contains(matchedAnchor) else { return movedAnchor(matchedAnchor) }

        return .matched(
            ProcessGroupEvidence(
                bootSessionID: bootSessionID,
                anchors: refreshed.sorted { ($0.pid, $0.startAbstime) < ($1.pid, $1.startAbstime) }
            )
        )
    }

    /// 検証とシグナル送出を同期的な1 APIに閉じ込める。
    /// 検証結果を呼び出し側へtokenとして渡さないため、時間を置いて再利用できない。
    static func identifyAndSend(
        _ signal: Int32,
        processGroupID: pid_t,
        evidence: ProcessGroupEvidence,
        groupStateProbe: @escaping GroupStateProbe = { ProcessInspector.processGroupState($0) },
        startAbstimeProbe: @escaping StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping BootSessionProbe = { ProcessInspector.bootSessionID() },
        sender: @escaping SignalSender = { kill(-$0, $1) }
    ) -> SignalOutcome {
        switch identify(
            processGroupID: processGroupID,
            evidence: evidence,
            groupStateProbe: groupStateProbe,
            startAbstimeProbe: startAbstimeProbe,
            bootSessionProbe: bootSessionProbe
        ) {
        case .empty:
            return .empty
        case let .notIdentified(reason):
            return .notIdentified(reason: reason)
        case let .unobservable(reason):
            return .unobservable(reason: reason)
        case let .matched(refreshedEvidence):
            guard sender(processGroupID, signal) != 0 else {
                return .sent(evidence: refreshedEvidence)
            }
            let code = errno
            return code == ESRCH ? .notPresent : .failed(errno: code)
        }
    }

    static func captureEvidence(
        processGroupID: pid_t,
        groupStateProbe: @escaping GroupStateProbe = { ProcessInspector.processGroupState($0) },
        startAbstimeProbe: @escaping StartAbstimeProbe = {
            ProcessInspector.startAbstimeObservation(pid: $0)
        },
        bootSessionProbe: @escaping BootSessionProbe = { ProcessInspector.bootSessionID() }
    ) -> ProcessGroupEvidence? {
        guard processGroupID > 0, let bootSessionID = bootSessionProbe() else { return nil }
        guard case let .success(members) = liveMembers(processGroupID, probe: groupStateProbe),
              !members.isEmpty,
              case let .success(anchors) = observeAnchors(members, probe: startAbstimeProbe),
              !anchors.isEmpty
        else { return nil }
        return ProcessGroupEvidence(
            bootSessionID: bootSessionID,
            anchors: anchors.sorted { ($0.pid, $0.startAbstime) < ($1.pid, $1.startAbstime) }
        )
    }

    private enum MemberLookup {
        case success([ProcessInspector.ProcessGroupMember])
        case failure(String)
    }

    private enum AnchorLookup {
        case success([ProcessAnchor])
        case failure(String)
    }

    private static func liveMembers(
        _ processGroupID: pid_t,
        probe: GroupStateProbe
    ) -> MemberLookup {
        switch probe(processGroupID) {
        case let .members(members):
            return .success(members.filter { !$0.isZombie })
        case let .unavailable(code):
            return .failure(
                L10n.text("""
                    プロセスグループ \(processGroupID) の状態を取得できませんでした\
                    （errno \(code): \(CStringDecoding.errorMessage(code))）。
                    """)
            )
        }
    }

    private static func observeAnchors(
        _ members: [ProcessInspector.ProcessGroupMember],
        probe: StartAbstimeProbe
    ) -> AnchorLookup {
        var anchors: [ProcessAnchor] = []
        for member in members {
            switch probe(member.pid) {
            case let .present(startAbstime):
                anchors.append(ProcessAnchor(pid: member.pid, startAbstime: startAbstime))
            case .notPresent:
                // group一覧取得後に終了した。次のgroup観測で所属を確かめ直す。
                continue
            case let .unavailable(code):
                return .failure(
                    L10n.text("""
                        プロセスグループ内の PID \(member.pid) の開始時刻を取得できませんでした\
                        （errno \(code): \(CStringDecoding.errorMessage(code))）。
                        """)
                )
            }
        }
        return .success(anchors)
    }

    private static func movedAnchor(_ anchor: ProcessAnchor) -> Result {
        .notIdentified(
            reason: L10n.text("""
                確認の途中で、根拠にしたプロセス（PID \(anchor.pid)）が\
                このプロセスグループから外れました。同一とは扱いません。
                """)
        )
    }
}
