import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("アプリ再起動後の再検証と引き継ぎ")
struct HandoffTests {
    private let bootSession = "BOOT-SESSION-A"

    private func makeHint(
        pid: pid_t = 4242,
        processGroupID: pid_t = 4242,
        startAbstime: UInt64 = 5_000,
        anchors: [(pid_t, UInt64)]? = nil,
        bootSessionID: String? = nil,
        executablePath: String = "/bin/sleep",
        workingDirectory: URL,
        ports: [Int] = [3000]
    ) -> RuntimeHint {
        RuntimeHint(
            projectID: UUID(),
            serviceID: UUID(),
            serviceName: "Web",
            processGroupID: processGroupID,
            leader: ProcessAnchor(pid: pid, startAbstime: startAbstime),
            groupEvidence: ProcessGroupEvidence(
                bootSessionID: bootSessionID ?? bootSession,
                anchors: (anchors ?? [(pid, startAbstime)]).map {
                    ProcessAnchor(pid: $0.0, startAbstime: $0.1)
                }
            ),
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            observedPorts: .observed(ports)
        )
    }

    private func inspector(
        startAbstime: UInt64?,
        executablePath: String?,
        workingDirectory: URL?,
        ports: [Int],
        portError: (any Error)? = nil,
        members: [pid_t] = [4242],
        bootSessionID: String? = nil
    ) -> HandoffInspector {
        HandoffInspector(
            startAbstimeProbe: { _ in
                startAbstime.map(ProcessInspector.StartAbstimeObservation.present) ?? .notPresent
            },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in executablePath },
            workingDirectoryProbe: { _ in workingDirectory },
            portProbe: { _ in
                if let portError { throw portError }
                return ports.map { ObservedPort(port: $0, pid: 4242, address: "127.0.0.1") }
            },
            groupStateProbe: { _ in
                .members(
                    members.map {
                        ProcessInspector.ProcessGroupMember(pid: $0, isZombie: false)
                    }
                )
            },
            bootSessionProbe: { bootSessionID ?? self.bootSession }
        )
    }

    private func load(_ hint: RuntimeHint) -> RuntimeHintsLoad {
        RuntimeHintsLoad(hints: [hint])
    }

    // MARK: - 現行形式

    @Test("錨・実行ファイル・作業ディレクトリ・ポートがすべて一致したものだけを候補にする")
    func acceptsFullyMatchingProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hint = makeHint(workingDirectory: directory)
        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [3000]
        ).review(load(hint))

        #expect(review.candidates.count == 1)
        #expect(review.rejected.isEmpty)
        #expect(review.candidates.first?.identity.startAbstime == 5_000)
        #expect(review.candidates.first?.observedPorts.map(\.port) == [3000])
    }

    @Test("PID が再利用されていたら引き継がない")
    func rejectsReusedPID() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 同じ PID だが開始 abstime が違う＝別プロセス。
        let review = await inspector(
            startAbstime: 9_999,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [3000]
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        #expect(review.stoppable.isEmpty)
        guard case .groupNotIdentified = review.rejected.first?.reason else {
            Issue.record("PID 再利用として扱われなかった: \(String(describing: review.rejected.first?.reason))")
            return
        }
    }

    @Test("起動セッションが違えば引き継がない")
    func rejectsDifferentBootSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [3000],
            bootSessionID: "BOOT-SESSION-B"
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        #expect(review.stoppable.isEmpty)
        #expect(review.rejected.count == 1)
    }

    @Test("プロセスが存在しなければ引き継がない")
    func rejectsMissingProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: nil,
            executablePath: nil,
            workingDirectory: nil,
            ports: [],
            members: []
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        #expect(review.rejected.first?.reason == .processGone
            || review.rejected.first != nil)
        #expect(review.unresolvedRejections.isEmpty)
        #expect(review.needsDecision == false)
    }

    @Test("実行ファイルが違えば引き継がないが、錨が一致するので停止はできる")
    func executableMismatchIsStoppableButNotAdoptable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/cat",
            workingDirectory: directory,
            ports: [3000]
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        // 本体の同一性は錨で確定しているので、停止手段は残る。
        let finding = try #require(review.stoppable.first)
        guard case .verifiedGroup = finding.evidence else {
            Issue.record("停止対象として提示されなかった: \(String(describing: finding.evidence))")
            return
        }
    }

    @Test("期待するポートを listen していなければ引き継がないが、停止はできる")
    func portMismatchIsStoppableButNotAdoptable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [3999]
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        let finding = try #require(review.stoppable.first)
        guard case let .matchedLeader(identity) = finding.evidence else {
            Issue.record("本体の同一性を根拠にした停止対象にならなかった: \(String(describing: finding.evidence))")
            return
        }
        #expect(identity.pid == 4242)
        #expect(finding.reason.contains("listen ポート"))
    }

    @Test("ポートを実測できない場合は、一致とみなさず引き継がない")
    func portObservationFailureIsNotAdoptable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [],
            portError: PortInspectorError.unparsableOutput(line: "n???")
        ).review(load(makeHint(workingDirectory: directory)))

        #expect(review.candidates.isEmpty)
        let finding = try #require(review.stoppable.first)
        guard case .matchedLeader = finding.evidence else {
            Issue.record("本体の同一性を根拠にした停止対象にならなかった: \(String(describing: finding.evidence))")
            return
        }
        #expect(finding.reason.contains("実測できませんでした"))
    }

    @Test("ポートを持たないサービスはポート照合を要求しない")
    func portlessServiceNeedsNoPortMatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: []
        ).review(load(makeHint(workingDirectory: directory, ports: [])))

        #expect(review.candidates.count == 1)
    }

    @Test("本体が終了していても、記録済みの子孫が残っていれば停止できる")
    func residualDescendantIsStoppable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hint = makeHint(
            anchors: [(4242, 5_000), (4300, 6_000)],
            workingDirectory: directory
        )
        let review = await HandoffInspector(
            // 本体は終了、子孫 4300 は生存。
            startAbstimeProbe: { pid in pid == 4300 ? .present(6_000) : .notPresent },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in nil },
            workingDirectoryProbe: { _ in nil },
            portProbe: { _ in [] },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 4300, isZombie: false)])
            },
            bootSessionProbe: { self.bootSession }
        ).review(load(hint))

        #expect(review.candidates.isEmpty)
        let finding = try #require(review.stoppable.first)
        guard case let .verifiedGroup(livePIDs) = finding.evidence else {
            Issue.record("残存グループとして提示されなかった: \(String(describing: finding.evidence))")
            return
        }
        #expect(livePIDs == [4300])
    }

    @Test("本体とプロセスグループが別を指す手掛かりは、照合そのものを行わない")
    func rejectsHintWhereLeaderAndGroupDiffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 起動したプロセスは必ずグループのリーダーなので、この組み合わせは成立しない。
        // 通してしまうと、無関係な leader の生存を根拠に別グループへ送れる。
        let broken = makeHint(pid: 4242, processGroupID: 9_999, workingDirectory: directory)
        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: [3000]
        ).review(load(broken))

        #expect(review.candidates.isEmpty)
        #expect(review.stoppable.isEmpty)
        guard case .inconsistentHint = review.rejected.first?.reason else {
            Issue.record("矛盾した手掛かりとして扱われなかった")
            return
        }
        // 判断できていないので、次回へ持ち越す。
        #expect(review.unresolvedRejections.count == 1)
    }

    @Test("本体は一致してもプロセスグループを観測できなければ、停止対象にしない")
    func doesNotOfferStopWhenGroupIsUnobservable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let review = await HandoffInspector(
            startAbstimeProbe: { _ in .present(5_000) },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in [] },
            // グループの状態が読めない。
            groupStateProbe: { _ in .unavailable(errno: EPERM) },
            bootSessionProbe: { self.bootSession }
        ).review(load(makeHint(workingDirectory: directory, ports: [])))

        #expect(review.candidates.isEmpty)
        // 観測できないものへシグナルを送る導線を出さない。
        #expect(review.stoppable.isEmpty)
        // 捨ててもよいとは判断しない。
        #expect(review.unresolvedRejections.count == 1)
    }

    @Test("実測できていないポート記録は引き継がず、停止対象にとどめる")
    func unobservedPortRecordIsNotAdoptable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var hint = makeHint(workingDirectory: directory, ports: [])
        hint = RuntimeHint(
            projectID: hint.projectID,
            serviceID: hint.serviceID,
            serviceName: hint.serviceName,
            processGroupID: hint.processGroupID,
            leader: hint.leader,
            groupEvidence: hint.groupEvidence,
            executablePath: hint.executablePath,
            workingDirectory: hint.workingDirectory,
            // 実測できていない。空配列と混同すると、
            // 「ポートを持たないサービス」として照合なしで引き継いでしまう。
            observedPorts: .unavailable
        )

        let review = await inspector(
            startAbstime: 5_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            ports: []
        ).review(load(hint))

        #expect(review.candidates.isEmpty)
        let finding = try #require(review.stoppable.first)
        guard case .matchedLeader = finding.evidence else {
            Issue.record("本体の同一性を根拠にした停止対象にならなかった")
            return
        }
    }

    // MARK: - 旧形式（v1）

    private func legacyHint(
        pid: pid_t,
        processGroupID: pid_t,
        startTimeMicroseconds: UInt64,
        executablePath: String,
        workingDirectory: URL
    ) -> LegacyRuntimeHint {
        LegacyRuntimeHint(
            projectID: UUID(),
            serviceID: UUID(),
            serviceName: "Legacy",
            pid: pid,
            processGroupID: processGroupID,
            startTimeMicroseconds: startTimeMicroseconds,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            observedPorts: []
        )
    }

    @Test("旧形式は、本体を確認できなければ停止対象にしない")
    func legacyHintWithoutLeaderIsNotStoppable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = legacyHint(
            pid: 4242,
            processGroupID: 4242,
            startTimeMicroseconds: 1_000_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory
        )
        let review = await HandoffInspector(
            startAbstimeProbe: { _ in .present(5_000) },
            // 本体が居ない。
            startTimeProbe: { _ in nil },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in [] },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 4242, isZombie: false)])
            },
            bootSessionProbe: { self.bootSession }
        ).review(RuntimeHintsLoad(hints: [], legacy: [legacy]))

        // 停止も引き継ぎもしない。安全な錨へ変換できないため。
        #expect(review.candidates.isEmpty)
        #expect(review.stoppable.isEmpty)
        guard case .legacyLeaderUnverified = review.rejected.first?.reason else {
            Issue.record("旧形式の未確認として扱われなかった: \(String(describing: review.rejected.first?.reason))")
            return
        }
    }

    @Test("旧形式でも、本体を確認できれば安定した錨へ変換する")
    func legacyHintWithVerifiedLeaderIsConverted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = legacyHint(
            pid: 4242,
            processGroupID: 4242,
            startTimeMicroseconds: 1_000_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory
        )
        let review = await HandoffInspector(
            startAbstimeProbe: { _ in .present(5_000) },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in [] },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 4242, isZombie: false)])
            },
            bootSessionProbe: { self.bootSession }
        ).review(RuntimeHintsLoad(hints: [], legacy: [legacy]))

        let candidate = try #require(review.candidates.first)
        // v1 の wall-clock 値ではなく、その場で実測した錨を持つ。
        #expect(candidate.hint.leader == ProcessAnchor(pid: 4242, startAbstime: 5_000))
        #expect(candidate.hint.groupEvidence.bootSessionID == bootSession)
    }

    @Test("旧形式で本体の開始時刻が一致しなければ変換しない")
    func legacyHintWithMismatchedLeaderIsNotConverted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = legacyHint(
            pid: 4242,
            processGroupID: 4242,
            startTimeMicroseconds: 1_000_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory
        )
        let review = await HandoffInspector(
            startAbstimeProbe: { _ in .present(5_000) },
            startTimeProbe: { _ in 9_999_999 },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in [] },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 4242, isZombie: false)])
            },
            bootSessionProbe: { self.bootSession }
        ).review(RuntimeHintsLoad(hints: [], legacy: [legacy]))

        #expect(review.candidates.isEmpty)
        #expect(review.stoppable.isEmpty)
    }

    @Test("旧形式のファイルは、変換できるまで捨てずに持ち回る")
    func legacyHintsSurviveSaving() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RuntimeHintStore(directory: directory)
        let json = """
        {
          "schemaVersion" : 1,
          "hints" : [
            {
              "projectID" : "\(UUID().uuidString)",
              "serviceID" : "\(UUID().uuidString)",
              "serviceName" : "Legacy",
              "pid" : 4242,
              "processGroupID" : 4242,
              "startTimeMicroseconds" : 1000000,
              "executablePath" : "/bin/sleep",
              "workingDirectory" : "\(directory.absoluteString)",
              "observedPorts" : [],
              "recordedAtMicroseconds" : 2000000
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()
        #expect(loaded.hints.isEmpty)
        #expect(loaded.legacy.count == 1)

        // 保存し直しても旧形式が消えない。
        try store.save([], legacy: loaded.legacy)
        let reloaded = try store.load()
        #expect(reloaded.legacy.count == 1)
    }

    // MARK: - 保存

    @Test("schema v2の整数ポート配列を現行形式へ移行して読み戻せる")
    func migratesV2ObservedPortsToCurrentSchema() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectID = UUID()
        let serviceID = UUID()
        let store = RuntimeHintStore(directory: directory)
        let json = """
        {
          "schemaVersion": 2,
          "hints": [
            {
              "projectID": "\(projectID.uuidString)",
              "serviceID": "\(serviceID.uuidString)",
              "serviceName": "Web",
              "processGroupID": 4242,
              "leader": { "pid": 4242, "startAbstime": 5000 },
              "groupEvidence": {
                "bootSessionID": "\(bootSession)",
                "anchors": [{ "pid": 4242, "startAbstime": 5000 }]
              },
              "executablePath": "/bin/sleep",
              "workingDirectory": "\(directory.absoluteString)",
              "observedPorts": [3000]
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)

        let migrated = try store.load()
        let hint = try #require(migrated.hints.first)
        #expect(hint.observedPorts == .observed([3000]))

        try store.save(migrated.hints, legacy: migrated.legacy)
        let savedJSON = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(savedJSON.contains("\"schemaVersion\" : 7"))
        #expect(try store.load() == migrated)
    }

    @Test("schema v3の手掛かりをmanaged commandなしで読み戻せる")
    func loadsV3RuntimeHintsWithoutManagedCommands() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeHintStore(directory: directory)
        let json = """
            {
              "schemaVersion": 3,
              "hints": [],
              "legacyHints": []
            }
            """
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()

        #expect(loaded.hints.isEmpty)
        #expect(loaded.legacy.isEmpty)
        #expect(loaded.managed.isEmpty)
    }

    @Test("schema v5でmanagedHintsが欠けていれば読み込みを失敗させる")
    func rejectsV5RuntimeHintsWithoutManagedHints() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeHintStore(directory: directory)
        let json = """
            {
              "schemaVersion": 5,
              "hints": [],
              "legacyHints": []
            }
            """
        try Data(json.utf8).write(to: store.fileURL)

        #expect(throws: RuntimeHintStoreError.self) {
            try store.load()
        }
    }

    @Test(
        "project_idを持たない旧schemaのmanaged hintは未検証のまま移行する",
        arguments: [4, 5]
    )
    func migratesLegacyManagedHintsAsUnverified(schemaVersion: Int) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeHintStore(directory: directory)
        let projectID = UUID()
        let serviceID = UUID()
        let json = """
            {
              "schemaVersion": \(schemaVersion),
              "hints": [],
              "legacyHints": [],
              "managedHints": [{
                "projectID": "\(projectID.uuidString)",
                "serviceID": "\(serviceID.uuidString)",
                "serviceName": "Supabase"
              }]
            }
            """
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()
        let hint = try #require(loaded.managed.first)
        // 構成同一性が無いので、この手掛かりからstatus/stopは実行できない。
        #expect(hint.identity == nil)
        #expect(hint.fingerprint == nil)
        #expect(hint.fingerprint == nil)
        #expect(hint.relationship == nil)

        try store.save(loaded.hints, legacy: loaded.legacy, managed: loaded.managed)
        let savedJSON = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(savedJSON.contains("\"schemaVersion\" : 7"))
        #expect(try store.load() == loaded)
    }

    @Test("schema v6のmanaged hintでキーが欠けていれば読み込みを失敗させる")
    func rejectsV6ManagedHintWithMissingKeys() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeHintStore(directory: directory)
        let json = """
            {
              "schemaVersion": 6,
              "hints": [],
              "legacyHints": [],
              "managedHints": [{
                "projectID": "\(UUID().uuidString)",
                "serviceID": "\(UUID().uuidString)",
                "serviceName": "Supabase"
              }]
            }
            """
        try Data(json.utf8).write(to: store.fileURL)

        #expect(throws: RuntimeHintStoreError.self) {
            try store.load()
        }
    }

    @Test("Supabaseの手掛かりをproject_id・設定ディレクトリ・管理関係ごと読み戻せる")
    func roundTripsManagedStackHints() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["start"],
            workingDirectory: directory
        )
        let projectID = try #require(SupabaseProjectID(rawValue: "demo"))
        let environmentID = UUID()
        let hint = try makeManagedStackHint(
                projectID: environmentID,
                service: service,
                supabaseProjectID: projectID,
                relationship: .adopted
            )
        let store = RuntimeHintStore(directory: directory)

        try store.save([], legacy: [], managed: [hint])
        let loaded = try store.load()

        #expect(loaded.hints.isEmpty)
        #expect(loaded.legacy.isEmpty)
        #expect(loaded.managed == [hint])
        let fingerprint = try #require(hint.fingerprint)
        let configDirectory = switch fingerprint {
        case let .supabase(supabaseFingerprint): supabaseFingerprint.configDirectory
        case .dockerCompose: preconditionFailure("Supabase fixture ではありません。")
        }
        #expect(configDirectory == directory.standardizedFileURL)
        #expect(hint.relationship == .adopted)

        // 起動コマンドが変わったら、この手掛かりを根拠に停止コマンドを組み立てない。
        var changedService = service
        changedService.start.arguments.append(contentsOf: ["--exclude", "studio"])
        func resolved(
            _ service: LaunchUnit,
            _ supabaseProjectID: SupabaseProjectID
        ) throws -> ResolvedManagedStack {
            try makeResolvedSupabaseStack(
                service,
                projectID: supabaseProjectID,
                environmentID: environmentID
            )
        }
        #expect(hint.matches(try resolved(service, projectID)))
        #expect(!hint.matches(try resolved(changedService, projectID)))
        #expect(hint.matches(try resolved(service, projectID)))
        // `project_id`が変わっていたら再検証しない。
        let otherID = try #require(SupabaseProjectID(rawValue: "sample"))
        #expect(!hint.matches(try resolved(service, otherID)))
        #expect(!hint.matches(try resolved(service, otherID)))
    }


    @Test("現行hint同士のserviceID重複をdecode時に拒否する")
    func rejectsDuplicateCurrentHintServiceIDs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeHint(workingDirectory: directory)
        let duplicate = RuntimeHint(
            projectID: UUID(),
            serviceID: first.serviceID,
            serviceName: "Duplicate",
            processGroupID: 5252,
            leader: ProcessAnchor(pid: 5252, startAbstime: 6_000),
            groupEvidence: ProcessGroupEvidence(
                bootSessionID: bootSession,
                anchors: [ProcessAnchor(pid: 5252, startAbstime: 6_000)]
            ),
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            observedPorts: .observed([])
        )
        let store = RuntimeHintStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            RuntimeHintsDocument(hints: [first, duplicate])
        ).write(to: store.fileURL)

        #expect(throws: RuntimeHintStoreError.self) {
            try store.load()
        }
    }

    @Test("現行hintとlegacy hintのserviceID重複をdecode時に拒否する")
    func rejectsCurrentAndLegacyHintServiceIDCollision() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let current = makeHint(workingDirectory: directory)
        let legacy = LegacyRuntimeHint(
            projectID: UUID(),
            serviceID: current.serviceID,
            serviceName: "Legacy Duplicate",
            pid: 6262,
            processGroupID: 6262,
            startTimeMicroseconds: 1_000_000,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            observedPorts: []
        )
        let store = RuntimeHintStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            RuntimeHintsDocument(hints: [current], legacyHints: [legacy])
        ).write(to: store.fileURL)

        #expect(throws: RuntimeHintStoreError.self) {
            try store.load()
        }
    }

    @Test("再検証の手掛かりはプロジェクト設定とは別ファイルへ保存する")
    func hintsAreStoredSeparately() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectStore = ProjectStore(directory: directory)
        let hintStore = RuntimeHintStore(directory: directory)
        #expect(projectStore.fileURL != hintStore.fileURL)

        let hint = makeHint(workingDirectory: directory)
        try hintStore.save([hint])
        #expect(try hintStore.load().hints == [hint])

        try projectStore.save([makeProject(directory: directory)])
        let projectJSON = try String(contentsOf: projectStore.fileURL, encoding: .utf8)
        for forbidden in ["\"leader\"", "\"groupEvidence\"", "\"startAbstime\""] {
            #expect(!projectJSON.contains(forbidden))
        }
    }

    @Test("実プロセスの錨を実測して照合できる")
    func measuresRealProcessAnchors() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let service = makeService(
            name: "Sleep",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        let log = EventLog()
        let stream = try await registry.start(service: service, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }
        #expect(await waitUntil { await log.startedRuntime != nil })
        // ポートを実測してから記録する。未実測のままだと、照合できない記録として
        // 引き継ぎ対象から外れる（それ自体は別のテストで確かめている）。
        try await registry.refreshPorts(serviceID: service.id)

        let hints = try await registry.runtimeHints()
        let hint = try #require(hints.first)

        #expect(hint.observedPorts.isObserved)
        #expect(ProcessInspector.startAbstime(pid: hint.leader.pid) == hint.leader.startAbstime)
        #expect(hint.groupEvidence.bootSessionID == ProcessInspector.bootSessionID())
        #expect(hint.groupEvidence.anchors.contains(hint.leader))

        let review = await HandoffInspector().review(RuntimeHintsLoad(hints: [hint]))
        #expect(review.candidates.count == 1)

        _ = try await registry.stop(service: service, grace: .seconds(5))
    }

    @Test("終了直前の保存で、後から生まれた子孫の錨が手掛かりへ入る")
    func hintsIncludeLateBornDescendants() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let spawnTrigger = directory.appendingPathComponent("spawn.trigger")
        let childPIDFile = directory.appendingPathComponent("late.pid")
        // 初回の手掛かりを取得してから、テスト側の合図で子を作る。
        let service = makeService(
            name: "Late",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                while [ ! -e "$1" ]; do
                    kill -0 "$4" 2>/dev/null && [ -d "$3" ] || exit 2
                    sleep 0.02
                done
                /bin/sh -c 'while kill -0 "$1" 2>/dev/null && [ -d "$2" ]; do sleep 0.05; done' late-child "$4" "$3" &
                printf '%s\\n' "$!" > "$2.tmp"
                mv "$2.tmp" "$2"
                wait
                """,
                "late-descendant",
                spawnTrigger.path,
                childPIDFile.path,
                directory.path,
                String(getpid()),
            ],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        let log = EventLog()
        let stream = try await registry.start(service: service, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }
        try #require(await waitUntil { await log.startedRuntime != nil })

        let earlyHints = try await registry.runtimeHints()
        let early = try #require(earlyHints.first { $0.serviceID == service.id })

        try Data().write(to: spawnTrigger, options: .atomic)
        try #require(await waitUntil { FileManager.default.fileExists(atPath: childPIDFile.path) })
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let childAnchor = ProcessAnchor(
            pid: childPID,
            startAbstime: try #require(ProcessInspector.startAbstime(pid: childPID))
        )

        let lateHints = try await registry.runtimeHints()
        let late = try #require(lateHints.first { $0.serviceID == service.id })

        // 一時的なsleepの増減ではなく、合図の後に生まれた子そのものが記録されたかを見る。
        #expect(!early.groupEvidence.anchors.contains(childAnchor))
        #expect(late.groupEvidence.anchors.contains(childAnchor))

        _ = try await registry.stop(service: service, grace: .seconds(5))
    }

    @Test("親が終了して孫だけ残ったサービスも、再起動後の対象に残る")
    func residualGrandchildSurvivesAppRestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderRelease = directory.appendingPathComponent("leader-release")

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let detached = makeService(
            name: "Detached",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                "attempt=0; while [ ! -e leader-release ] && [ \"$attempt\" -lt 500 ]; do sleep 0.02; attempt=$((attempt + 1)); done; [ -e leader-release ] || exit 2; sleep 120 &"
            ],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [detached])

        let log = EventLog()
        let stream = try await registry.start(service: detached, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        let runtime = try #require(await waitForValue(timeout: .seconds(5)) {
            await log.startedRuntime
        })
        defer { kill(-runtime.processGroupID, SIGKILL) }
        try Data().write(to: leaderRelease)
        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await registry.isRunning(serviceID: detached.id) == false)
        let processGroupID = try #require(
            await registry.occupiedProcessGroup(serviceID: detached.id)
        )
        #expect(processGroupID == runtime.processGroupID)

        let hints = try await registry.runtimeHints()
        let hint = try #require(hints.first { $0.serviceID == detached.id })
        #expect(hint.processGroupID == processGroupID)

        let review = await HandoffInspector().review(RuntimeHintsLoad(hints: [hint]))
        #expect(review.candidates.isEmpty)
        let finding = try #require(review.stoppable.first)
        guard case let .verifiedGroup(livePIDs) = finding.evidence else {
            Issue.record("残存グループとして提示されなかった: \(String(describing: finding.evidence))")
            return
        }
        #expect(!livePIDs.isEmpty)

        let freshRegistry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let coordinator = SwitchCoordinator(
            registry: freshRegistry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(stopGrace: .seconds(5))
        )
        let outcome = try await coordinator.stopWithoutAdopting(
            finding,
            service: detached,
            in: project
        )
        #expect(outcome.isStopped)
        #expect(ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false)
    }

    @Test("登録した残存グループのプロセスグループと実測ポートを取得できる")
    func residualGroupSnapshotExposesGroupAndPorts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let reserved = try LocalTCPServer(behavior: .silent)
        let port = reserved.port
        reserved.stop()

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/usr/bin/nc -l \(port) & sleep 0.2; exit 0"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )
        defer {
            kill(-spawned.processGroupID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(spawned.pid, &status, WNOHANG)
        }

        let leader = try #require(
            await waitForValue { ProcessAnchor.measure(pid: spawned.pid) }
        )
        #expect(await waitUntil {
            let holders = try? await PortInspector.holders(ofPorts: [port])
            return holders?.isEmpty == false
        })
        let evidence = try #require(
            ProcessGroupIdentification.captureEvidence(processGroupID: spawned.processGroupID)
        )

        #expect(await waitUntil {
            var status: Int32 = 0
            return waitpid(spawned.pid, &status, WNOHANG) == spawned.pid
        })

        let service = makeService(
            name: "Holder",
            kind: .worker,
            ports: [PortSpec(port: port, isPrimary: true)],
            executable: "/bin/sh",
            arguments: ["-c", "true"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        let hint = RuntimeHint(
            projectID: project.id,
            serviceID: service.id,
            serviceName: service.name,
            processGroupID: spawned.processGroupID,
            leader: leader,
            groupEvidence: evidence,
            executablePath: "/bin/sh",
            workingDirectory: directory,
            observedPorts: .observed([port])
        )

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        try await registry.registerResidualGroup(hint: hint, service: try #require(service.processDefinition), in: project)
        try await registry.refreshPorts(serviceID: service.id)

        let snapshot = try #require(await registry.runtimeSnapshot(serviceID: service.id))
        #expect(snapshot.processID == nil)
        #expect(snapshot.processGroupID == spawned.processGroupID)
        #expect(snapshot.observedPorts.map(\.port).contains(port))
    }

    @Test("引き継いだサービスも、プロジェクトの停止対象に含める")
    func adoptedServiceIsStoppedWithTheProject() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )
        defer {
            kill(-spawned.processGroupID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(spawned.pid, &status, 0)
        }

        let identity = try #require(
            await waitForValue {
                ProcessInspector.identity(pid: spawned.pid, workingDirectory: directory)
            }
        )
        let evidence = try #require(
            ProcessGroupIdentification.captureEvidence(processGroupID: spawned.processGroupID)
        )

        let service = makeService(
            name: "Adopted",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["60"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        let hint = RuntimeHint(
            projectID: project.id,
            serviceID: service.id,
            serviceName: service.name,
            processGroupID: spawned.processGroupID,
            leader: identity.anchor,
            groupEvidence: evidence,
            executablePath: identity.executablePath,
            workingDirectory: directory,
            observedPorts: .observed([])
        )

        let review = await HandoffInspector().review(RuntimeHintsLoad(hints: [hint]))
        let candidate = try #require(review.candidates.first)

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .seconds(5),
                startupObservationWindow: .milliseconds(200),
                startupPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        try await coordinator.adopt(candidate, service: service, in: project)
        #expect(await registry.isRunning(serviceID: service.id))
        #expect(await coordinator.servicePhase(service, in: project) == .healthy)

        let outcome = try await coordinator.stop(project)
        #expect(outcome.facts.source?.phase == .stopped)
        #expect(await registry.isRunning(serviceID: service.id) == false)
    }

    @Test("引き継いだ実プロセスを停止できる")
    func adoptsAndStopsRealProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )

        let identity = try #require(
            await waitForValue {
                ProcessInspector.identity(pid: spawned.pid, workingDirectory: directory)
            }
        )
        let evidence = try #require(
            ProcessGroupIdentification.captureEvidence(processGroupID: spawned.processGroupID)
        )

        let supervisor = AdoptedSupervisor(
            serviceID: UUID(),
            serviceName: "Adopted",
            identity: identity,
            processGroupID: spawned.processGroupID,
            observedPorts: [],
            evidence: evidence
        )
        #expect(await supervisor.isRunning())
        #expect(await supervisor.stop(grace: .seconds(5)) == .stopped(nil))
        #expect(await supervisor.isRunning() == false)

        var status: Int32 = 0
        _ = waitpid(spawned.pid, &status, 0)
    }
}
