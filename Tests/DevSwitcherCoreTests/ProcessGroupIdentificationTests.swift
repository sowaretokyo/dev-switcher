import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("プロセスグループの同定")
struct ProcessGroupIdentificationTests {
    private let bootSession = "BOOT-SESSION-A"

    private func evidence(_ anchors: [(pid_t, UInt64)]) -> ProcessGroupEvidence {
        ProcessGroupEvidence(
            bootSessionID: bootSession,
            anchors: anchors.map { ProcessAnchor(pid: $0.0, startAbstime: $0.1) }
        )
    }

    private func members(
        _ pids: [pid_t],
        zombies: Set<pid_t> = []
    ) -> ProcessInspector.ProcessGroupState {
        .members(
            pids.map {
                ProcessInspector.ProcessGroupMember(pid: $0, isZombie: zombies.contains($0))
            }
        )
    }

    private func present(_ value: UInt64) -> ProcessInspector.StartAbstimeObservation {
        .present(value)
    }

    // MARK: - 錨の照合

    @Test("記録した錨と完全一致するメンバーが居れば同定する")
    func identifiesGroupWithMatchingAnchor() {
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession }
        )
        #expect(result.evidence?.anchors == [ProcessAnchor(pid: 100, startAbstime: 5_000)])
    }

    @Test("起動セッションが違えば、同じ PID・PGID でも同定しない")
    func rejectsDifferentBootSession() {
        // mach absolute time は再起動でリセットされるため、同じ値が別プロセスに付きうる。
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { "BOOT-SESSION-B" }
        )
        guard case let .notIdentified(reason) = result else {
            Issue.record("再起動をまたいで同定してしまった: \(result)")
            return
        }
        #expect(reason.contains("起動セッション"))
    }

    @Test("起動セッションを取得できなければ、退避せず観測不能として扱う")
    func unobservableBootSessionFailsClosed() {
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { nil }
        )
        guard case .unobservable = result else {
            Issue.record("観測不能として扱われなかった: \(result)")
            return
        }
    }

    @Test("PGID が同じでも錨が一致しなければ同定しない")
    func rejectsRecycledProcessGroup() {
        // PID も PGID も同じだが、開始 abstime が違う＝別プロセス。
        // 以前は wall-clock の時間窓と作業ディレクトリで通していた経路。
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(9_999) },
            bootSessionProbe: { self.bootSession }
        )
        guard case let .notIdentified(reason) = result else {
            Issue.record("再利用されたグループを同定してしまった: \(result)")
            return
        }
        #expect(reason.contains("再利用"))
    }

    @Test("wall-clock が巻き戻っても、判定は錨だけで決まる")
    func wallClockRollbackDoesNotAffectIdentification() {
        // 同定に wall-clock を渡す口が無いことを、時計に依存しない結果で確かめる。
        // 巻き戻した時計なら「記録の時間窓に入る」プロセスでも、錨が違えば同定しない。
        let matching = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession }
        )
        #expect(matching.evidence != nil)

        let rolledBack = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(1) },
            bootSessionProbe: { self.bootSession }
        )
        guard case .notIdentified = rolledBack else {
            Issue.record("錨が違うのに同定してしまった: \(rolledBack)")
            return
        }
    }

    @Test("後から生まれたメンバーを錨へ加える")
    func refreshesAnchorsWithNewMembers() {
        // A（記録済み）と B（後発）が居る状態。B を錨へ入れないと、
        // A が終了したあとにグループを同定できなくなる。
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100, 200]) },
            startAbstimeProbe: { pid in self.present(pid == 100 ? 5_000 : 7_000) },
            bootSessionProbe: { self.bootSession }
        )
        #expect(
            result.evidence?.anchors == [
                ProcessAnchor(pid: 100, startAbstime: 5_000),
                ProcessAnchor(pid: 200, startAbstime: 7_000),
            ]
        )
    }

    @Test("錨を取り直している間に元の錨が消えたら、更新しない")
    func doesNotUpdateWhenAnchorDisappearsMidway() {
        // 最初の照合は通るが、再確認の時点で入れ替わっている状況。
        let calls = CallCounter()
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { pid in
                guard pid == 100 else { return self.present(7_000) }
                // 照合 → 取り直し → 再確認 の3回目で値が変わる。
                return self.present(calls.next() < 3 ? 5_000 : 8_000)
            },
            bootSessionProbe: { self.bootSession }
        )
        guard case let .notIdentified(reason) = result else {
            Issue.record("入れ替わったのに更新してしまった: \(result)")
            return
        }
        #expect(reason.contains("このプロセスグループから外れました"))
    }

    @Test("錨が生存していても、対象のプロセスグループから外れていれば同定しない")
    func rejectsAnchorThatLeftTheProcessGroup() {
        // 錨のプロセス自体は生きているが、確認の途中で別グループへ移った状況。
        // 開始 abstime の再確認だけでは通ってしまい、再利用後のグループへ送りうる。
        let calls = CallCounter()
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(200, 7_000)]),
            groupStateProbe: { _ in
                // 1回目はメンバー、2回目は既に外れている。
                calls.next() == 1 ? self.members([200]) : self.members([300])
            },
            startAbstimeProbe: { pid in self.present(pid == 200 ? 7_000 : 9_000) },
            bootSessionProbe: { self.bootSession }
        )
        guard case let .notIdentified(reason) = result else {
            Issue.record("グループから外れた錨で同定してしまった: \(result)")
            return
        }
        #expect(reason.contains("このプロセスグループから外れました"))
    }

    @Test("ゾンビしか残っていなければ、停止対象なしとして扱う")
    func zombieOnlyGroupIsEmpty() {
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100], zombies: [100]) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession }
        )
        #expect(result == .empty)
    }

    @Test("プロセスグループを観測できない場合は、居ないとも別物とも扱わない")
    func unobservableGroupIsDistinct() {
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in .unavailable(errno: EPERM) },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession }
        )
        guard case .unobservable = result else {
            Issue.record("観測不能として扱われなかった: \(result)")
            return
        }
    }

    @Test("読み取れないメンバーがいれば観測不能として扱う")
    func unreadableMemberMakesIdentificationUnobservable() {
        // 別利用者のプロセスは開始 abstime を取得できない。
        // 「取得できない」を 0 などの固定値にすると、無関係なプロセスが一致してしまう。
        let result = ProcessGroupIdentification.identify(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in .unavailable(errno: EPERM) },
            bootSessionProbe: { self.bootSession }
        )
        guard case .unobservable = result else {
            Issue.record("読み取れないメンバーを観測不能として扱わなかった: \(result)")
            return
        }
    }

    // MARK: - 停止側

    @Test("3回目の所属確認で錨が外れていればシグナルを送らない")
    func doesNotSignalWhenAnchorLeavesAfterSecondPass() {
        let calls = CallCounter()
        let recorder = SignalRecorder()
        let outcome = ProcessGroupIdentification.identifyAndSend(
            SIGTERM,
            processGroupID: 100,
            evidence: evidence([(200, 7_000)]),
            groupStateProbe: { _ in
                switch calls.next() {
                case 1, 2: self.members([200])
                default: self.members([300])
                }
            },
            startAbstimeProbe: { pid in self.present(pid == 200 ? 7_000 : 9_000) },
            bootSessionProbe: { self.bootSession },
            sender: { recorder.send($0, $1) }
        )

        guard case .notIdentified = outcome else {
            Issue.record("[A] → [A] → [B] を同定した: \(outcome)")
            return
        }
        #expect(recorder.count == 0)
    }

    @Test("2回目の観測が空ならemptyとしてシグナルを送らない")
    func doesNotSignalWhenSecondPassIsEmpty() {
        let calls = CallCounter()
        let recorder = SignalRecorder()
        let outcome = ProcessGroupIdentification.identifyAndSend(
            SIGTERM,
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in
                calls.next() == 1 ? self.members([100]) : self.members([])
            },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession },
            sender: { recorder.send($0, $1) }
        )

        #expect(outcome == .empty)
        #expect(recorder.count == 0)
    }

    @Test("3回目の観測が空ならemptyとしてシグナルを送らない")
    func doesNotSignalWhenThirdPassIsEmpty() {
        let calls = CallCounter()
        let recorder = SignalRecorder()
        let outcome = ProcessGroupIdentification.identifyAndSend(
            SIGTERM,
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in
                calls.next() < 3 ? self.members([100]) : self.members([])
            },
            startAbstimeProbe: { _ in self.present(5_000) },
            bootSessionProbe: { self.bootSession },
            sender: { recorder.send($0, $1) }
        )

        #expect(outcome == .empty)
        #expect(recorder.count == 0)
    }

    @Test("同定できないプロセスグループへはシグナルを送らない")
    func doesNotSignalUnidentifiedGroup() async {
        let supervisor = ResidualGroupSupervisor(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            // 錨が一致しない＝再利用されたグループ。
            startAbstimeProbe: { _ in self.present(9_999) },
            bootSessionProbe: { self.bootSession }
        )

        let outcome = await supervisor.stop(grace: .milliseconds(200))
        guard case let .residual(_, reason) = outcome else {
            Issue.record("同定できないのに停止済みとして扱われた: \(outcome)")
            return
        }
        #expect(reason.contains("同定できませんでした"))
    }

    @Test("再利用されたプロセスグループへは強制終了も送らない")
    func doesNotForceStopRecycledGroup() async {
        let supervisor = ResidualGroupSupervisor(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            groupStateProbe: { _ in self.members([100]) },
            startAbstimeProbe: { _ in self.present(9_999) },
            bootSessionProbe: { self.bootSession }
        )
        guard case .residual = await supervisor.forceStop(grace: .milliseconds(200)) else {
            Issue.record("再利用されたグループへ SIGKILL を送った")
            return
        }
    }

    @Test("引き継いだ本体を見失ったあと、再利用されたプロセスグループを自分の資源と主張しない")
    func adoptedSupervisorDoesNotClaimRecycledGroup() async {
        let identity = ProcessIdentity(
            pid: 100,
            startAbstime: 5_000,
            startedAt: Date(timeIntervalSince1970: 0),
            executablePath: "/bin/sleep",
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let supervisor = AdoptedSupervisor(
            serviceID: UUID(),
            serviceName: "Web",
            identity: identity,
            processGroupID: 100,
            observedPorts: [],
            evidence: evidence([(100, 5_000)]),
            // 本体は終了し、PGID を別プロセスが再利用している。
            startAbstimeProbe: { pid in pid == 100 ? .notPresent : self.present(9_999) },
            groupStateProbe: { _ in self.members([777]) },
            bootSessionProbe: { self.bootSession }
        )

        #expect(await supervisor.isOccupyingResources() == false)
        guard case .residual = await supervisor.stop(grace: .milliseconds(200)) else {
            Issue.record("再利用されたグループへシグナルを送った")
            return
        }
    }

    @Test("引き継いだ本体を見失っても、記録済みの子孫が残っていれば同定できる")
    func adoptedSupervisorIdentifiesRecordedDescendant() async {
        let identity = ProcessIdentity(
            pid: 100,
            startAbstime: 5_000,
            startedAt: Date(timeIntervalSince1970: 0),
            executablePath: "/bin/sleep",
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let supervisor = AdoptedSupervisor(
            serviceID: UUID(),
            serviceName: "Web",
            identity: identity,
            processGroupID: 100,
            observedPorts: [],
            evidence: evidence([(100, 5_000), (200, 7_000)]),
            startAbstimeProbe: { pid in pid == 100 ? .notPresent : self.present(7_000) },
            groupStateProbe: { _ in self.members([200]) },
            bootSessionProbe: { self.bootSession }
        )

        #expect(await supervisor.isRunning() == false)
        #expect(await supervisor.isOccupyingResources())
    }

    @Test("引き継ぎsupervisorのポート観測失敗はunavailableとして残る")
    func adoptedPortFailureIsUnavailable() async {
        let identity = ProcessIdentity(
            pid: 100,
            startAbstime: 5_000,
            startedAt: Date(timeIntervalSince1970: 0),
            executablePath: "/bin/sleep",
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let supervisor = AdoptedSupervisor(
            serviceID: UUID(),
            serviceName: "Web",
            identity: identity,
            processGroupID: 100,
            observedPorts: [ObservedPort(port: 3000, pid: 100, address: "127.0.0.1")],
            evidence: evidence([(100, 5_000)]),
            portProbe: { _ in
                throw PortInspectorError.unparsableOutput(line: "broken")
            }
        )

        await #expect(throws: PortInspectorError.self) {
            try await supervisor.refreshPorts()
        }
        #expect(await supervisor.observedPorts == .unavailable)
    }

    @Test("残存group supervisorのポート観測失敗はunavailableとして残る")
    func residualPortFailureIsUnavailable() async {
        let supervisor = ResidualGroupSupervisor(
            processGroupID: 100,
            evidence: evidence([(100, 5_000)]),
            portProbe: { _ in
                throw PortInspectorError.unparsableOutput(line: "broken")
            }
        )

        await #expect(throws: PortInspectorError.self) {
            try await supervisor.refreshPorts()
        }
        #expect(await supervisor.observedPorts == .unavailable)
    }

    // MARK: - 実プロセスでの検証

    /// A（SIGTERM で終了・記録済み）と B（SIGTERM を無視・後発）を持つグループを作る。
    private func spawnGroupWithLateSurvivor(
        in directory: URL
    ) throws -> (spawned: SpawnedProcess, readyA: URL, readyB: URL) {
        let script = directory.appendingPathComponent("group.sh")
        let readyA = directory.appendingPathComponent("a.ready")
        let readyB = directory.appendingPathComponent("b.ready")
        // 準備完了の合図は、それぞれのプロセス自身に書かせる。
        // 親が代わりに書くと、B が trap を仕掛ける前に SIGTERM が届いて素直に終了し、
        // 「SIGTERM を無視する子孫が残る」状況にならない。
        try """
        #!/bin/sh
        /bin/sh -c 'echo a > "\(readyA.path)"; while true; do sleep 0.2; done' &
        sleep 1
        /bin/sh -c 'trap "" TERM; echo b > "\(readyB.path)"; while true; do sleep 0.2; done' &
        sleep 120
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(executableURL: script, arguments: [], workingDirectory: directory),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )
        return (spawned, readyA, readyB)
    }

    @Test("SIGTERM で古い錨のプロセスだけが終了しても、後発の子孫を根拠に強制終了できる")
    func forceStopsSurvivorAfterAnchorProcessExits() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let group = try spawnGroupWithLateSurvivor(in: directory)
        defer {
            kill(-group.spawned.processGroupID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(group.spawned.pid, &status, WNOHANG)
        }

        // A が居る時点で錨を記録する。B はまだ生まれていない。
        #expect(await waitUntil { FileManager.default.fileExists(atPath: group.readyA.path) })
        let recorded = try #require(
            ProcessGroupIdentification.captureEvidence(
                processGroupID: group.spawned.processGroupID
            )
        )
        #expect(await waitUntil { FileManager.default.fileExists(atPath: group.readyB.path) })

        let supervisor = ResidualGroupSupervisor(
            processGroupID: group.spawned.processGroupID,
            evidence: recorded
        )

        // 停止を試みる。送信直前に錨を取り直すので、B も錨に入る。
        let stopOutcome = await supervisor.stop(grace: .seconds(2))
        guard case .residual = stopOutcome else {
            Issue.record("SIGTERM を無視する子孫が残っていない: \(stopOutcome)")
            return
        }

        // A は終了し、B だけが残っている。錨を更新していなければここで同定できない。
        #expect(await supervisor.forceStop(grace: .seconds(5)).isStopped)
        #expect(
            ProcessInspector.processGroupState(group.spawned.processGroupID)
                .hasLiveMembers == false
        )
    }

    @Test("錨を更新しないままでは、古い錨のプロセス終了後に同定できなくなる")
    func staleEvidenceCannotIdentifyAfterAnchorExits() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let group = try spawnGroupWithLateSurvivor(in: directory)
        defer {
            kill(-group.spawned.processGroupID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(group.spawned.pid, &status, WNOHANG)
        }

        #expect(await waitUntil { FileManager.default.fileExists(atPath: group.readyA.path) })
        let recorded = try #require(
            ProcessGroupIdentification.captureEvidence(
                processGroupID: group.spawned.processGroupID
            )
        )
        #expect(await waitUntil { FileManager.default.fileExists(atPath: group.readyB.path) })

        // 錨を更新する supervisor で SIGTERM を送り、A を終了させる。
        let live = ResidualGroupSupervisor(
            processGroupID: group.spawned.processGroupID,
            evidence: recorded
        )
        _ = await live.stop(grace: .seconds(2))

        // 記録当時の錨しか持たない側は、もう同定できない。
        // これが「錨を更新しないと回収不能になる」ことの証明。
        let stale = ResidualGroupSupervisor(
            processGroupID: group.spawned.processGroupID,
            evidence: recorded
        )
        guard case .notIdentified = await stale.identify() else {
            Issue.record("古い錨のまま同定できてしまった")
            return
        }

        _ = await live.forceStop(grace: .seconds(5))
    }
}

/// 呼び出し回数を数えるだけの補助。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// 送出されたシグナルを記録する。0件であることの確認に使う。
final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(processGroupID: pid_t, signal: Int32)] = []

    func send(_ processGroupID: pid_t, _ signal: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        records.append((processGroupID, signal))
        return 0
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    var signals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.signal)
    }
}
