import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("Supabaseスタックの同一性と観測")
struct SupabaseStackTests {
    // MARK: - config.toml の project_id

    @Test("トップレベルの project_id だけを読み、コメントと別sectionを誤認しない")
    func readsOnlyTopLevelProjectID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeSupabaseConfigText(
            """
            # project_id = "commented-out"
            project_id = "bell" # 使うのはこの行だけ
            [db]
            project_id = "other-section"
            """,
            in: directory
        )

        let projectID = try SupabaseConfigFile.projectID(inConfigDirectory: directory)

        #expect(projectID.rawValue == "bell")
        #expect(url.lastPathComponent == "config.toml")
    }

    @Test("設定ファイルが無ければ、ディレクトリ名で補完せず失敗する")
    func rejectsMissingConfigFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: SupabaseConfigError.self) {
            try SupabaseConfigFile.projectID(inConfigDirectory: directory)
        }
    }

    @Test(
        "欠落・空・重複・解釈不能な project_id を具体的なエラーで拒否する",
        arguments: [
            // トップレベルに project_id が無い
            "[db]\nproject_id = \"bell\"",
            // 空文字
            "project_id = \"\"",
            // トップレベルで重複
            "project_id = \"bell\"\nproject_id = \"penta\"",
            // 引用符が無い裸の値
            "project_id = bell",
            // 閉じていない
            "project_id = \"bell",
            // 複数行文字列
            "project_id = \"\"\"bell\"\"\"",
            // 正しいTOMLエスケープも、未対応の間は誤変換せず拒否する
            #"project_id = "\u0062ell""#,
            // 不正なTOMLエスケープ
            #"project_id = "\q""#,
        ]
    )
    func rejectsUnusableProjectID(text: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeSupabaseConfigText(text, in: directory)

        #expect(throws: SupabaseConfigError.self) {
            try SupabaseConfigFile.projectID(inConfigDirectory: directory)
        }
    }

    @Test("コンテナ名へ使えない project_id を拒否する")
    func rejectsUnsupportedProjectIDValue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeSupabaseConfigText("project_id = \"--all\"", in: directory)

        #expect(throws: SupabaseConfigError.self) {
            try SupabaseConfigFile.projectID(inConfigDirectory: directory)
        }
        #expect(SupabaseProjectID(rawValue: "--all") == nil)
        #expect(SupabaseProjectID(rawValue: "bell stack") == nil)
        #expect(SupabaseProjectID(rawValue: "bell-2.stack_x")?.rawValue == "bell-2.stack_x")
    }

    // MARK: - Docker inventory の分類

    private func record(
        name: String,
        label: String? = "bell",
        status: String = "running",
        health: String? = "healthy"
    ) -> SupabaseContainerRecord {
        SupabaseContainerRecord(
            containerID: name,
            name: "/\(name)",
            projectLabel: label,
            status: status,
            health: health
        )
    }

    private func observation(
        _ records: [SupabaseContainerRecord]
    ) throws -> SupabaseContainerObservation? {
        guard case let .observed(result) = SupabaseDockerContract.classify(records) else {
            return nil
        }
        return result[try #require(SupabaseProjectID(rawValue: "bell"))]
    }

    @Test("コンテナ0件は停止中として扱い、volumeを数えない")
    func classifiesEmptyInventoryAsNotRunning() throws {
        guard case let .observed(result) = SupabaseDockerContract.classify([]) else {
            Issue.record("観測できるはずのinventoryをunobservableにした")
            return
        }
        #expect(result.isEmpty)
        #expect(ManagedStackSnapshot(type: .supabase, observations: []).state(
            of: ManagedStackIdentity(try #require(SupabaseProjectID(rawValue: "bell")))
        ) == .notRunning)
    }

    @Test("DBコンテナがrunningかつhealthyならDB健全として扱う")
    func classifiesHealthyDatabase() throws {
        let result = try observation([
            record(name: "supabase_db_bell"),
            record(name: "supabase_kong_bell"),
        ])
        #expect(result == .databaseHealthy)
    }

    @Test("DB欠損・停止・unhealthyはdegradedにする")
    func classifiesDegradedDatabase() throws {
        #expect(isDegraded(try observation([record(name: "supabase_kong_bell")])))
        #expect(isDegraded(try observation([
            record(name: "supabase_db_bell", status: "exited", health: nil),
        ])))
        #expect(isDegraded(try observation([
            record(name: "supabase_db_bell", health: "unhealthy"),
        ])))
    }

    @Test("health不明・DB候補重複・未対応stateは停止中へ倒さずunknownにする")
    func classifiesIndeterminateStates() throws {
        #expect(isIndeterminate(try observation([record(name: "supabase_db_bell", health: nil)])))
        #expect(isIndeterminate(try observation([
            record(name: "supabase_db_bell", health: "starting"),
        ])))
        #expect(isIndeterminate(try observation([
            record(name: "supabase_db_bell"),
            record(name: "supabase_db_bell_2"),
        ])))
        #expect(isIndeterminate(try observation([
            record(name: "supabase_db_bell", status: "unknown-state", health: nil),
        ])))
    }

    @Test("ラベル欠落や解釈不能なラベルは観測全体を失敗にする")
    func rejectsMissingOrUnparsableLabel() {
        for label in [nil, "bell stack"] {
            let result = SupabaseDockerContract.classify([
                record(name: "supabase_db_bell", label: label),
            ])
            guard case .unobservable = result else {
                Issue.record("ラベル「\(String(describing: label))」を停止中へ倒した")
                continue
            }
        }
    }

    @Test("docker出力のJSONを解釈できなければ観測を失敗させる")
    func rejectsBrokenDockerJSON() {
        #expect(throws: SupabaseInventoryError.self) {
            _ = try SupabaseDockerContract.containerIDs(fromListOutput: "{ not json }")
        }
        #expect(throws: SupabaseInventoryError.self) {
            _ = try SupabaseDockerContract.records(fromInspectOutput: "{\"Id\":\"a\"}")
        }
    }

    @Test("docker出力からIDとラベル・状態を読み取る")
    func parsesDockerOutput() throws {
        let ids = try SupabaseDockerContract.containerIDs(
            fromListOutput: "{\"ID\":\"abc\",\"Names\":\"supabase_db_bell\"}\n"
        )
        #expect(ids == ["abc"])

        let records = try SupabaseDockerContract.records(
            fromInspectOutput: """
                {"Id":"abc","Name":"/supabase_db_bell","Config":{"Labels":{"com.supabase.cli.project":"bell"}},"State":{"Status":"running","Health":{"Status":"healthy"}}}
                """
        )
        #expect(records.count == 1)
        #expect(records[0].projectLabel == "bell")
        #expect(records[0].status == "running")
        #expect(records[0].health == "healthy")
    }

    private func isDegraded(_ observation: SupabaseContainerObservation?) -> Bool {
        if case .degraded = observation { return true }
        return false
    }

    private func isIndeterminate(_ observation: SupabaseContainerObservation?) -> Bool {
        if case .indeterminate = observation { return true }
        return false
    }

    // MARK: - 実測状態の組み立て

    private func makeDriver(_ world: FakeSupabaseWorld) -> SupabaseStackDriver {
        SupabaseStackDriver(
            inventory: world,
            runner: world,
            options: SupabaseStackDriver.Options(
                startConfirmationWindow: .milliseconds(200),
                stopConfirmationWindow: .milliseconds(200),
                pollInterval: .milliseconds(10)
            )
        )
    }

    @Test("設定ディレクトリが既知なら status の成功まで確認して running とする")
    func requiresStatusSuccessForKnownStack() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let service = makeSupabaseService(workingDirectory: directory)
        let stack = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("bell"))
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let driver = makeDriver(world)

        let running = await driver.observe(known: [stack])
        #expect(running.state(of: ManagedStackIdentity(projectID)) == .running)

        // DBはhealthyでもstatusが失敗するなら確定できない。停止中へ倒さない。
        await world.failStatus(.exit(code: 1))
        let unknown = await driver.observe(known: [stack])
        #expect(unknown.state(of: ManagedStackIdentity(projectID)) == .unknown)

        // 設定ディレクトリが不明な外部スタックは、DBの実測だけで稼働中とする。
        let external = await driver.observe(known: [])
        #expect(external.state(of: ManagedStackIdentity(projectID)) == .running)
    }

    @Test("Dockerを読めないときは既知のスタックをunknownにする")
    func unobservableDockerYieldsUnknown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let service = makeSupabaseService(workingDirectory: directory)
        let stack = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("bell"))
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
        let world = FakeSupabaseWorld()
        await world.failInventory("docker daemon が応答しません。")

        let snapshot = await makeDriver(world).observe(known: [stack])

        #expect(snapshot.state(of: ManagedStackIdentity(projectID)) == .unknown)
        #expect(snapshot.hasUnknown)
    }

    @Test("停止は終了コード0だけで判断せず、notRunningの再観測まで求める")
    func stopRequiresNotRunningConfirmation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let service = makeSupabaseService(workingDirectory: directory)
        let stack = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("bell"))
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        await world.keepStackAfterStop(true)
        let driver = makeDriver(world)

        await #expect(throws: ManagedStackOperationError.self) {
            _ = try await driver.stop(
                ManagedStackIdentity(projectID),
                using: stack,
                known: [stack]
            )
        }
        #expect(await world.commandLines.contains { $0.contains("--project-id bell") })
    }

    @Test("inventory全体の観測失敗は、設定のないIDもunknownとして保持する")
    func unknownInventoryDoesNotImplyAbsentExternalStack() async throws {
        let world = FakeSupabaseWorld(stacks: ["external": .databaseHealthy])
        await world.failInventory("Docker unavailable")
        let driver = makeDriver(world)
        let projectID = try #require(SupabaseProjectID(rawValue: "external"))

        let snapshot = await driver.observe(known: [])
        #expect(snapshot.hasUnknown)
        #expect(snapshot.state(of: ManagedStackIdentity(projectID)) == .unknown)
        let observation = await driver.observe(ManagedStackIdentity(projectID), known: [])
        #expect(observation.state == .unknown)
        #expect(observation.detail == "Docker unavailable")
    }

    @Test("未登録スタックの停止後にinventoryを読めなければ停止成功にしない")
    func externalStopRequiresObservableInventory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = try makeResolvedSupabaseStack(
            makeSupabaseService(workingDirectory: directory), projectID: makeSupabaseProjectID("external")
        )
        let projectID = try #require(SupabaseProjectID(rawValue: "external"))
        let world = FakeSupabaseWorld(stacks: ["external": .databaseHealthy])
        await world.keepStackAfterStop(true)
        await world.failInventory("Docker unavailable")

        await #expect(throws: ManagedStackOperationError.self) {
            _ = try await makeDriver(world).stop(
                ManagedStackIdentity(projectID), using: stack, known: []
            )
        }
        #expect(await world.runningProjectIDs == ["external"])
    }
}

/// 生の`config.toml`本文を書き出す。parserの分岐を直接確かめるために使う。
@discardableResult
private func writeSupabaseConfigText(_ text: String, in directory: URL) throws -> URL {
    let configDirectory = directory.appendingPathComponent("supabase", isDirectory: true)
    try FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: true
    )
    let url = configDirectory.appendingPathComponent("config.toml")
    try Data(text.utf8).write(to: url)
    return url
}
