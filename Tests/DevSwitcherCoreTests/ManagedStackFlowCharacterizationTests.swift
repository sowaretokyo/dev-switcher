import Foundation
import Testing
@testable import DevSwitcherCore

/// 起動・切替・復元の流れの中で組み立てられる文言を固定する特性テスト。
/// 実Docker・実Supabaseには触れず、`FakeSupabaseWorld` だけを世界にする。
@Suite("管理対象スタックの特性（流れの中の文言）")
struct ManagedStackFlowCharacterizationTests {
    private func makeStack(
        world: FakeSupabaseWorld,
        logDirectory: URL
    ) -> (RuntimeRegistry, SwitchCoordinator, SupabaseStackDriver) {
        let controller = SupabaseStackDriver(
            inventory: world,
            runner: world,
            options: SupabaseStackDriver.Options(
                startConfirmationWindow: .milliseconds(300),
                stopConfirmationWindow: .milliseconds(300),
                pollInterval: .milliseconds(10)
            )
        )
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: logDirectory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in [] },
            stackDrivers: [.supabase: controller]
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(150),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        return (registry, coordinator, controller)
    }

    private func supabaseProject(
        name: String = "Bell",
        projectID: String = "bell",
        directory: URL
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: projectID, in: directory)
        return makeProject(
            name: name,
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )
    }

    private func failure(from operation: () async throws -> some Sendable) async throws -> SwitchFailure {
        do {
            _ = try await operation()
        } catch {
            return try #require(error as? SwitchFailure)
        }
        Issue.record("失敗するはずの操作が成功した")
        throw CancellationError()
    }

    // MARK: - (a) project_id を確認できません

    @Test("起動コマンドの構造不備は「project_idを確認できません」に「開発環境名」のサービス名: 理由 を連結する")
    func structuralDefectJoinsIntoProjectIDMessage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeProject(
            name: "Bell",
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory, arguments: ["status"])]
        )
        let (_, coordinator, _) = makeStack(world: FakeSupabaseWorld(), logDirectory: directory)

        let thrown = try await failure {
            try await coordinator.start(project, registeredProjects: [project])
        }

        #expect(thrown.reason.title == "未対応の設定")
        #expect(
            thrown.reason
                == .unsupportedConfiguration(
                    "Supabaseの`project_id`を確認できません。\n"
                        + "「Bell」の Supabase: 起動コマンドに `start` サブコマンドがありません。"
                )
        )
    }

    @Test("config.toml が無い場合は、設定ファイルの欠落メッセージを連結する")
    func missingConfigJoinsIntoProjectIDMessage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeProject(
            name: "Bell",
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )
        let (_, coordinator, _) = makeStack(world: FakeSupabaseWorld(), logDirectory: directory)

        let thrown = try await failure {
            try await coordinator.start(project, registeredProjects: [project])
        }

        let configPath = directory.standardizedFileURL.path + "/supabase/config.toml"
        #expect(
            thrown.reason
                == .unsupportedConfiguration(
                    "Supabaseの`project_id`を確認できません。\n"
                        + "「Bell」の Supabase: Supabaseの設定ファイルがありません（\(configPath)）。"
                )
        )
    }

    @Test("project_idの解決エラーが複数あれば、登録順に改行で連結する")
    func multipleResolutionErrorsAreJoinedByNewline() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bellDirectory = root.appendingPathComponent("bell", isDirectory: true)
        let pentaDirectory = root.appendingPathComponent("penta", isDirectory: true)
        for directory in [bellDirectory, pentaDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let bell = makeProject(
            name: "Bell",
            directory: bellDirectory,
            services: [makeSupabaseService(workingDirectory: bellDirectory, arguments: ["status"])]
        )
        let penta = makeProject(
            name: "Penta",
            directory: pentaDirectory,
            services: [makeSupabaseService(workingDirectory: pentaDirectory, arguments: ["start", "--all"])]
        )
        let (_, coordinator, _) = makeStack(world: FakeSupabaseWorld(), logDirectory: root)

        let thrown = try await failure {
            try await coordinator.start(bell, registeredProjects: [bell, penta])
        }

        #expect(
            thrown.reason
                == .unsupportedConfiguration(
                    "Supabaseの`project_id`を確認できません。\n"
                        + "「Bell」の Supabase: 起動コマンドに `start` サブコマンドがありません。\n"
                        + "「Penta」の Supabase: 起動コマンドに `--all` と `--no-backup` は指定できません。"
                )
        )
    }

    // MARK: - (b) 単体起動の拒否 / (c) Registry の専用経路の案内

    @Test("Supabaseの単体起動・再起動は Coordinator が固定文言で拒否する")
    func coordinatorRejectsStandaloneSupabaseStartAndRestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let (_, coordinator, _) = makeStack(world: FakeSupabaseWorld(), logDirectory: directory)
        let message = "Supabaseは通常プロセスと停止・状態確認の方法が異なるため、単体の起動・再起動はできません。"

        let startFailure = try await failure {
            try await coordinator.startService(service, in: project)
        }
        #expect(startFailure.reason == .unsupportedConfiguration(message))

        let restartFailure = try await failure {
            try await coordinator.restart(service, in: project)
        }
        #expect(restartFailure.reason == .unsupportedConfiguration(message))
    }

    @Test("Registry の通常起動経路は、Supabaseを専用経路の案内つきで拒否する")
    func registryRejectsSupabaseOnOrdinaryPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let (registry, _, _) = makeStack(world: FakeSupabaseWorld(), logDirectory: directory)

        do {
            _ = try await registry.start(service: service, in: project)
            Issue.record("Supabaseが通常経路で起動できてしまった")
        } catch let error as RuntimeError {
            #expect(
                error.description
                    == "サービス「Supabase」の管理コマンドを構成できません。\n"
                    + "スタックは専用の起動処理を使用してください。"
            )
        }
    }

    // MARK: - (d) 実測結果なしの起動拒否

    // 「既存スタックの実測結果がないため、Supabaseを起動しません。」（startPhase 内）は
    // 現行コードでは到達できない。startPhase の対象一覧と resolveSupabasePlan の探索が
    // 同じ `enabledStartupOrder` を使い、preflight が2件目のSupabaseを弾くため、
    // Supabaseを起動する時点で計画は必ず存在する。文言はここでは固定できない。

    // MARK: - (e) restoreManagedStack の skip 理由

    private func decodeUnverifiedManagedHint(
        project: ProjectDefinition,
        service: LaunchUnit
    ) throws -> ManagedStackHint {
        // 旧schemaから移行した「未検証の手掛かり」は、3項目すべてが明示的な null。
        let json = """
            {
              "projectID": "\(project.id.uuidString)",
              "stackID": "\(service.id.uuidString)",
              "stackName": "\(service.name)",
              "type": "supabase",
              "identity": null,
              "fingerprint": null,
              "relationship": null
            }
            """
        return try JSONDecoder().decode(ManagedStackHint.self, from: Data(json.utf8))
    }

    @Test("旧形式の手掛かり（relationship なし）は状態確認コマンドを実行せず skip する")
    func restoreSkipsLegacyHint() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (_, coordinator, _) = makeStack(world: world, logDirectory: directory)
        let hint = try decodeUnverifiedManagedHint(project: project, service: service)

        let outcome = await coordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )

        #expect(
            outcome
                == .skipped(
                    reason: "旧形式の手掛かりには`project_id`と設定の記録がないため、状態確認コマンドを実行しません。"
                )
        )
        #expect(await world.commandLines.isEmpty)
    }

    @Test("現在の設定から project_id を解決できなければ skip する")
    func restoreSkipsWhenProjectIDUnresolvable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let hint = try makeManagedStackHint(
                projectID: project.id, service: service,
                supabaseProjectID: try makeSupabaseProjectID("bell"), relationship: .launched
            )
        // 保存後に config.toml を失った状態。
        try FileManager.default.removeItem(at: directory.appendingPathComponent("supabase"))
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (_, coordinator, _) = makeStack(world: world, logDirectory: directory)

        let outcome = await coordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )

        #expect(
            outcome
                == .skipped(
                    reason: "現在の設定から`project_id`を解決できないため、状態確認コマンドを実行しません。"
                )
        )
        #expect(await world.commandLines.isEmpty)
    }

    @Test("保存時の project_id と現在の設定が違えば skip する")
    func restoreSkipsOnConfigurationMismatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let hint = try makeManagedStackHint(
                projectID: project.id, service: service,
                supabaseProjectID: try makeSupabaseProjectID("bell"), relationship: .adopted
            )
        // サービス定義は同じまま、config.toml の project_id だけが変わった状態。
        try writeSupabaseConfig(projectID: "penta", in: directory)
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (_, coordinator, _) = makeStack(world: world, logDirectory: directory)

        let outcome = await coordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )

        #expect(
            outcome
                == .skipped(
                    reason: "保存時の設定ディレクトリ・起動コマンド・`project_id`と一致しないため、状態確認コマンドを実行しません。"
                )
        )
        #expect(await world.commandLines.isEmpty)
    }

    // 「Supabaseの必須コンテナが揃っていません。」（degraded で detail が nil のときの既定理由）は
    // 現行コードでは到達できない。degraded の観測は必ず Docker 側の理由文字列を detail に持つ。
    // また失敗理由は Coordinator の内部辞書にあり、公開APIでは `.residual` に潰れて読めない。
    @Test("degraded を再検証して復元すると、起動済みにせず停止導線（残存あり）を残す")
    func restoreDegradedKeepsStopPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let hint = try makeManagedStackHint(
                projectID: project.id, service: service,
                supabaseProjectID: try makeSupabaseProjectID("bell"), relationship: .launched
            )
        let world = FakeSupabaseWorld(stacks: ["bell": .degraded(reason: "DBコンテナがありません")])
        let (registry, coordinator, _) = makeStack(world: world, logDirectory: directory)

        let outcome = await coordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )

        #expect(outcome == .restored(.degraded))
        #expect(await registry.managedRelationship(stackID: service.id) == .restored)
        #expect(await coordinator.servicePhase(service, in: project) == .residual)
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") && !$0.contains(" start") })
    }

    @Test("running を再検証して復元すると起動済みになり、notRunning なら手掛かりの破棄を促す")
    func restoreRunningAndNotRunning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let hint = try makeManagedStackHint(
                projectID: project.id, service: service,
                supabaseProjectID: try makeSupabaseProjectID("bell"), relationship: .launched
            )
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (registry, coordinator, _) = makeStack(world: world, logDirectory: directory)

        let restored = await coordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )
        #expect(restored == .restored(.running))
        #expect(await registry.managedRelationship(stackID: service.id) == .restored)
        #expect(await coordinator.servicePhase(service, in: project) == .healthy)

        let freshWorld = FakeSupabaseWorld()
        let (_, freshCoordinator, _) = makeStack(world: freshWorld, logDirectory: directory)
        let notRunning = await freshCoordinator.restoreManagedStack(
            hint: hint, service: service, in: project, registeredProjects: [project]
        )
        #expect(notRunning == .notRunning)
    }

    // MARK: - (f) 承認済み停止の進捗イベント

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [SwitchState] = []

        func record(_ state: SwitchState) {
            lock.lock()
            defer { lock.unlock() }
            states.append(state)
        }

        var all: [SwitchState] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }
    }

    @Test("承認済みの別スタック停止は、ID昇順に「Supabase <id>」を index/total つきで通知する")
    func approvedStopsEmitProgressInOrder() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bellDirectory = root.appendingPathComponent("bell", isDirectory: true)
        try FileManager.default.createDirectory(at: bellDirectory, withIntermediateDirectories: true)
        let project = try supabaseProject(directory: bellDirectory)
        let world = FakeSupabaseWorld(stacks: [
            "penta": .databaseHealthy,
            "legacy": .degraded(reason: "DBコンテナが exited 状態です。"),
        ])
        let (_, coordinator, _) = makeStack(world: world, logDirectory: root)

        let thrown = try await failure {
            try await coordinator.start(project, registeredProjects: [project])
        }
        guard case let .managedStackConfirmationRequired(plan) = thrown.reason else {
            Issue.record("確認要求ではない失敗: \(thrown.reason)")
            return
        }
        #expect(plan.primaryEntry.action == .start)
        #expect(plan.stopEntries.map(\.identity.value) == ["legacy", "penta"])

        let recorder = ProgressRecorder()
        _ = try await coordinator.start(
            project,
            registeredProjects: [project],
            approval: plan.approval,
            progress: { recorder.record($0) }
        )

        let stopping = recorder.all.filter {
            if case .stopping = $0 { return true }
            return false
        }
        #expect(
            stopping == [
                .stopping(service: "Supabase legacy", index: 1, total: 2),
                .stopping(service: "Supabase penta", index: 2, total: 2),
            ]
        )
        #expect(
            stopping.map(\.label) == [
                "Supabase legacy を停止（1/2）",
                "Supabase penta を停止（2/2）",
            ]
        )
        #expect(await world.runningProjectIDs == ["bell"])
    }

    // MARK: - (g) 観測 detail

    @Test("DBがhealthyでも status が失敗する場合の detail は、終了状態と出力を連結する")
    func statusFailureDetail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let bell = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("bell"))
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        await world.failStatus(.exit(code: 1))
        let (_, _, controller) = makeStack(world: world, logDirectory: directory)

        let snapshot = await controller.observe(known: [bell])

        let observation = snapshot.observation(of: try makeSupabaseIdentity("bell"))
        #expect(observation.state == .unknown)
        #expect(
            observation.detail
                == "DBコンテナはhealthyですが `supabase status` が失敗しました（終了コード 1）。\nfailed"
        )
        #expect(snapshot.failureDetails == [
            "bell: DBコンテナはhealthyですが `supabase status` が失敗しました（終了コード 1）。\nfailed",
        ])
    }

    @Test("status を実行できない場合の detail は、実行不能の理由を連結する")
    func statusUnavailableDetail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let bell = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("bell"))
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        await world.failStatus(.unavailable("supabase が PATH にありません。"))
        let (_, _, controller) = makeStack(world: world, logDirectory: directory)

        let snapshot = await controller.observe(known: [bell])

        let workdir = directory.standardizedFileURL.path
        #expect(snapshot.state(of: try makeSupabaseIdentity("bell")) == .unknown)
        #expect(
            snapshot.observation(of: try makeSupabaseIdentity("bell")).detail
                == "`supabase status` を実行できません。\n"
                + "コマンド「supabase status --workdir \(workdir) --output json」を実行できません。\n"
                + "supabase が PATH にありません。"
        )
    }

    @Test("設定ディレクトリが不明な外部スタックは、DBの実測だけで running になり status を実行しない")
    func unknownConfigurationStackIsRunningByInventoryOnly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (_, _, controller) = makeStack(world: world, logDirectory: directory)

        let snapshot = await controller.observe(known: [])

        #expect(snapshot.state(of: try makeSupabaseIdentity("bell")) == .running)
        #expect(snapshot.observation(of: try makeSupabaseIdentity("bell")).detail == nil)
        #expect(await world.commandLines.isEmpty)
    }
}
