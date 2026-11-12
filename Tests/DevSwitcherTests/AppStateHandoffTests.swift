import Darwin
@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 画面状態を組み立てる層の検証。
///
/// 保存先も実行環境も必ず一時ディレクトリへ差し替える。既定のままだと、
/// 設定・手掛かりに加えてサービスのログまで利用者の Application Support へ書き込む。
@Suite("引き継ぎ操作の画面状態")
@MainActor
struct AppStateHandoffTests {
    /// テスト用の`project_id`。`#require`のネストを避けるため定数で持つ。
    private var demoStackID: SupabaseProjectID {
        guard let projectID = SupabaseProjectID(rawValue: "demo") else {
            preconditionFailure("テスト用の project_id が不正です。")
        }
        return projectID
    }

    /// Supabase 1件だけの開発環境。`project_id`は`supabase/config.toml`から解決する。
    private func makeSupabaseProject(
        name: String = "Demo",
        projectID: String = "demo",
        directory: URL
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: projectID, in: directory)
        return ProjectDefinition(
            name: name,
            color: .blue,
            directory: directory,
            services: [makeAppStateSupabaseService(workingDirectory: directory)]
        )
    }

    @Test("アプリ起動では外部スタックを検出しても確認を出さない")
    func launchObservesExternalStackWithoutConfirmation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        // 手掛かりなしで同一スタックが動いている＝外部スタック。
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        #expect(state.managedStackConfirmation == nil)
        #expect(state.phase(of: project) == .stopped)
        // 観測だけ。引き継ぎも停止もしない。
        let serviceID = try #require(project.launchUnits.first?.id)
        let observed = try #require(state.state(of: serviceID).managedStack)
        #expect(observed.state == .running)
        #expect(observed.label == "外部・稼働中")
        #expect(observed.relationship == nil)
        #expect(state.hasManagedResources(in: project) == false)
        #expect(state.activeProject == nil)
        #expect(state.canStart)
        #expect(try RuntimeHintStore(directory: directory).load().managed.isEmpty)
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
        #expect(await world.runningProjectIDs == ["demo"])

        // フォアグラウンド復帰でも確認は出さない。
        await state.applicationDidBecomeActive()
        #expect(state.managedStackConfirmation == nil)

        await world.setStack("demo", .degraded(reason: "DB unhealthy"))
        await state.applicationDidBecomeActive()
        #expect(state.state(of: serviceID).managedStack?.label == "外部・一部だけ稼働")
        #expect(state.state(of: serviceID).managedStack?.detail == "DB unhealthy")
        await world.failInventory("Docker unavailable")
        await state.applicationDidBecomeActive()
        #expect(state.state(of: serviceID).managedStack?.state == .unknown)
        #expect(state.state(of: serviceID).managedStack?.detail == "Docker unavailable")
        #expect(state.managedStackObservationError == "Docker unavailable")
        #expect(state.hasManagedResources(in: project) == false)

        await world.failInventory(nil)
        await world.setStack("demo", nil)
        await state.applicationDidBecomeActive()
        #expect(state.state(of: serviceID).managedStack?.state == .notRunning)
        #expect(state.managedStackObservationError == nil)
        #expect(state.managedStackConfirmation == nil)
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
    }

    @Test("停止を確認したSupabaseの外部再起動では管理を戻さず、再度引き継ぎ確認を出す",
          arguments: [false, true])
    func externallyRestartedSupabaseRequiresNewApproval(observedStop: Bool) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let serviceID = try #require(project.launchUnits.first?.id)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld()
        let hintStore = RuntimeHintStore(directory: directory)
        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        #expect(state.state(of: serviceID).managedStack?.relationship == .launched)

        if observedStop {
            await world.setStack("demo", nil)
            await state.applicationDidBecomeActive()
        } else {
            state.stopProject(project)
            await state.waitForPendingOperation()
        }
        #expect(state.state(of: serviceID).managedStack?.relationship == nil)
        #expect(try hintStore.load().managed.isEmpty)

        await world.setStack("demo", .databaseHealthy)
        await world.resetCommands()
        await state.applicationDidBecomeActive()
        #expect(state.state(of: serviceID).managedStack?.label == "外部・稼働中")
        #expect(state.hasManagedResources(in: project) == false)
        #expect(state.activeProject == nil)
        #expect(state.canStart)
        #expect(state.managedStackConfirmation == nil)
        #expect(try hintStore.load().managed.isEmpty)

        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        let confirmation = try #require(state.managedStackConfirmation)
        #expect(confirmation.plan.primaryEntry.action == .adopt)
        state.cancelManagedStackConfirmation()
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
        #expect(await world.runningProjectIDs == ["demo"])

        // 停止確認で破棄した手掛かりを、次回起動時に復元しない。
        let relaunched = makeAppState(directory: directory, supabaseWorld: world)
        await relaunched.bootstrap()
        #expect(relaunched.state(of: serviceID).managedStack?.label == "外部・稼働中")
        #expect(relaunched.hasManagedResources(in: project) == false)
    }

    @Test("未登録の外部SupabaseもID・実測状態・観測理由を画面へ渡す")
    func externalSupabaseWithoutRegistrationIsVisible() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["external": .indeterminate(reason: "Unsupported state")])
        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        let external = try #require(state.unregisteredManagedStackObservations.first)
        #expect(external.identity.value == "external")
        #expect(external.state == .unknown)
        #expect(external.detail == "Unsupported state")
        #expect(state.activeProject == nil)
        #expect(state.managedStackConfirmation == nil)
        #expect(await world.commandLines.isEmpty)
    }

    @Test("起動を押したときだけ確認を出し、キャンセルでコマンドを1件も実行しない")
    func confirmationAppearsOnlyOnStartAndCancelChangesNothing() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        await world.resetCommands()

        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()

        let presentation = try #require(state.managedStackConfirmation)
        #expect(presentation.plan.primaryEntry.action == .adopt)
        #expect(presentation.plan.primaryEntry.identity.value == "demo")
        #expect(presentation.plan.stopEntries.isEmpty)
        #expect(state.canStart == false)
        #expect(state.canChangeConfiguration == false)

        state.cancelManagedStackConfirmation()

        #expect(state.managedStackConfirmation == nil)
        #expect(state.phase(of: project) == .stopped)
        // 確認をキャンセルした場合、start/stopは1件も実行しない。
        #expect(await world.commandLines.allSatisfy { !$0.contains("start") })
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(await world.runningProjectIDs == ["demo"])
    }

    @Test("引き継ぎを承認するとstartを実行せず、開発環境の停止でstopできる")
    func approvedAdoptionSkipsStartAndStopsWithProject() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        let hintStore = RuntimeHintStore(directory: directory)

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()

        let presentation = try #require(state.managedStackConfirmation)
        await world.resetCommands()
        state.approveManagedStackConfirmation(presentation)
        await state.waitForPendingOperation()

        #expect(state.managedStackConfirmation == nil)
        #expect(state.phase(of: project) == .running)
        #expect(await world.commandLines.allSatisfy { !$0.contains(" start") })

        // 引き継いだスタックは、通常の停止操作で停止できる。
        let hint = try #require(hintStore.load().managed.first)
        #expect(hint.relationship == .adopted)
        #expect(hint.identity?.value == "demo")

        state.stopProject(project)
        await state.waitForPendingOperation()

        #expect(state.phase(of: project) == .stopped)
        #expect(await world.runningProjectIDs.isEmpty)
        #expect(try hintStore.load().managed.isEmpty)
    }

    @Test("引き継ぎ後に別サービスがblockで失敗しても、引き継いだSupabaseを止めない")
    func adoptedSupabaseSurvivesBlockingFailureAsResidual() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "demo", in: directory)
        let supabase = makeAppStateSupabaseService(workingDirectory: directory)
        let failing = LaunchUnit(
            name: "Web",
            kind: .web,
            ports: [],
            start: CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", "exit 3"],
                workingDirectory: directory
            ),
            enabledByDefault: true,
            failurePolicy: .block
        )
        let project = ProjectDefinition(
            name: "Demo",
            color: .blue,
            directory: directory,
            services: [supabase, failing]
        )
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        let presentation = try #require(state.managedStackConfirmation)
        state.approveManagedStackConfirmation(presentation)
        await state.waitForPendingOperation()

        // 引き継いだスタックは巻き戻さない。残存ありとして停止導線を残す。
        #expect(state.phase(of: project) == .residual)
        #expect(await world.runningProjectIDs == ["demo"])
        #expect(state.canStop)

        state.stopProject(project)
        await state.waitForPendingOperation()
        #expect(state.phase(of: project) == .stopped)
        #expect(await world.runningProjectIDs.isEmpty)
    }

    @Test("引き継ぎ済みの手掛かりを再起動後に実測して restored へ戻す")
    func restoresManagedHintAfterRelaunch() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save(
            [],
            legacy: [],
            managed: [
                try #require(
                    makeManagedStackHint(
                        projectID: project.id,
                        service: service,
                        supabaseProjectID: demoStackID,
                        relationship: .launched
                    )
                ),
            ]
        )
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        #expect(state.phase(of: project) == .running)
        #expect(state.managedStackConfirmation == nil)
        #expect(state.managedHintError == nil)

        state.stopProject(project)
        await state.waitForPendingOperation()

        #expect(state.phase(of: project) == .stopped)
        #expect(await world.runningProjectIDs.isEmpty)
    }

    @Test("設定が変わった手掛かりではstatusもstopも実行しない")
    func changedConfigurationHintIsNotExecuted() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalDirectory = directory.appendingPathComponent("original", isDirectory: true)
        let currentDirectory = directory.appendingPathComponent("current", isDirectory: true)
        for path in [originalDirectory, currentDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try writeSupabaseConfig(projectID: "demo", in: path)
        }

        let originalService = makeAppStateSupabaseService(workingDirectory: originalDirectory)
        let hint = try #require(
            makeManagedStackHint(
                projectID: UUID(),
                service: originalService,
                supabaseProjectID: demoStackID,
                relationship: .launched
            )
        )
        var currentService = originalService
        currentService.start.workingDirectory = currentDirectory
        let project = ProjectDefinition(
            id: hint.projectID,
            name: "Demo",
            color: .blue,
            directory: currentDirectory,
            services: [currentService]
        )
        try ProjectStore(directory: directory).save([project])
        try RuntimeHintStore(directory: directory).save([], legacy: [], managed: [hint])
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        #expect(state.managedHintError?.contains("保存時の設定") == true)
        #expect(state.hasDiscardableManagedHints)
        #expect(state.canStart == false)
        // 一致しない手掛かりからは、状態確認も停止も実行しない。
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
    }

    @Test("project_idが変わったmanaged hintを画面から破棄できる")
    func changedProjectIDHintCanBeDiscarded() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(projectID: "demo", directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        let hintStore = RuntimeHintStore(directory: directory)
        let hint = try #require(
            makeManagedStackHint(
                projectID: project.id,
                service: service,
                supabaseProjectID: demoStackID,
                relationship: .launched
            )
        )
        try hintStore.save([], legacy: [], managed: [hint])

        // サービス定義とコマンドは同じまま、config.tomlのIDだけが変わった状態。
        try writeSupabaseConfig(projectID: "sample", in: directory)
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        let state = makeAppState(directory: directory, supabaseWorld: world)

        await state.bootstrap()

        #expect(state.managedHintError?.contains("`project_id`と一致しない") == true)
        #expect(state.hasDiscardableManagedHints)
        #expect(state.canStart == false)

        await state.discardUnmatchedManagedHints()

        #expect(state.managedHintError == nil)
        #expect(state.hasDiscardableManagedHints == false)
        #expect(try hintStore.load().managed.isEmpty)
        #expect(state.canStart)
        #expect(state.canChangeConfiguration)
    }

    @Test("旧schemaの手掛かりでは現在設定のstatusを実行しない")
    func legacyManagedHintIsNotExecuted() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        let hintStore = RuntimeHintStore(directory: directory)
        let json = """
            {
              "schemaVersion": 5,
              "hints": [],
              "legacyHints": [],
              "managedHints": [{
                "projectID": "\(project.id.uuidString)",
                "serviceID": "\(service.id.uuidString)",
                "serviceName": "\(service.name)"
              }]
            }
            """
        try Data(json.utf8).write(to: hintStore.fileURL)
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        #expect(state.managedHintError?.contains("旧形式の手掛かり") == true)
        #expect(state.hasDiscardableManagedHints)
        #expect(state.canStart == false)
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
    }

    @Test("状態を判定できないSupabaseは通常hintエラーと分けて表示する")
    func unobservableSupabaseHasDedicatedErrorState() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        try RuntimeHintStore(directory: directory).save(
            [],
            legacy: [],
            managed: [
                try #require(
                    makeManagedStackHint(
                        projectID: project.id,
                        service: service,
                        supabaseProjectID: demoStackID,
                        relationship: .launched
                    )
                ),
            ]
        )
        let world = FakeSupabaseWorld()
        await world.failInventory("docker が応答しません。")

        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()

        #expect(state.managedHintError?.contains("docker が応答しません。") == true)
        #expect(state.hintError == nil)
        #expect(state.hasDiscardableManagedHints == false)
        #expect(state.canStart == false)
    }

    @Test("定義がないmanaged hintを明示的かつ保存成功時だけ破棄する")
    func missingManagedHintCanBeDiscardedTransactionally() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)
        try writeSupabaseConfig(projectID: "demo", in: directory)
        let missingService = makeAppStateSupabaseService(workingDirectory: directory)
        let missing = try #require(
            makeManagedStackHint(
                projectID: UUID(),
                service: missingService,
                supabaseProjectID: demoStackID,
                relationship: .launched
            )
        )
        try hintStore.save([], legacy: [], managed: [missing])

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()

        #expect(state.managedHintError?.contains("対応するSupabase設定が見つからない") == true)
        #expect(state.hintError == nil)
        #expect(state.hasDiscardableManagedHints)
        #expect(state.canStart == false)

        hintStore.failAllSaves()
        await state.discardUnmatchedManagedHints()

        #expect(state.hasDiscardableManagedHints)
        #expect(try hintStore.load().managed == [missing])

        hintStore.allowSaves()
        await state.discardUnmatchedManagedHints()

        #expect(state.managedHintError == nil)
        #expect(state.hasDiscardableManagedHints == false)
        #expect(try hintStore.load().managed.isEmpty)
        #expect(state.canChangeConfiguration)
    }


    @Test("UIはポート観測不能をlistenなしと区別して表示する")
    func unavailablePortObservationHasDistinctUILabel() {
        var unavailable = AppState.ServiceUIState()
        unavailable.phase = .running
        unavailable.observedPortRecord = .unavailable
        #expect(unavailable.observedPortsAvailabilityText == "取得不能")

        var empty = AppState.ServiceUIState()
        empty.phase = .running
        empty.observedPortRecord = .observed([])
        #expect(empty.observedPortsAvailabilityText == "listen なし")
    }

    @Test("ポート更新失敗の警告はhint保存成功後も消えない")
    func portRefreshWarningSurvivesSuccessfulHintSave() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in
                throw PortInspectorError.unparsableOutput(line: "broken")
            },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )
        let state = AppState(
            registry: registry,
            store: ProjectStore(directory: directory),
            hintStore: RuntimeHintStore(directory: directory),
            coordinatorOptions: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            )
        )

        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let processGroupID = state.state(of: project.services[0].id).processGroupID {
                kill(-processGroupID, SIGKILL)
            }
        }

        #expect(state.operationError == nil)
        #expect(state.hintError?.contains("listen ポートを更新できない") == true)
        #expect(state.state(of: project.services[0].id).observedPortRecord == .unavailable)
        let hint = try #require(
            RuntimeHintStore(directory: directory).load().hints.first
        )
        #expect(hint.observedPorts == .unavailable)
    }

    /// 判断待ちの候補として提示させてから、本体だけを終了させる。
    /// 「検証してからボタンを押すまでの間に本体が終了した」状況を実プロセスで作る。
    private func presentRaceCondition(
        state: AppState,
        project: ProjectDefinition,
        directory: URL
    ) async throws -> (
        presentationID: UUID,
        hint: RuntimeHint,
        processGroupID: pid_t,
        cleanup: TestProcessGroupCleanup
    ) {
        let quitFile = directory.appendingPathComponent("leader.quit")
        let testProcessID = getpid()
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                // 孫を残したまま、合図を受けてから本体だけが終了する。
                arguments: [
                    "-c",
                    """
                    /bin/sh -c 'remaining=600; while kill -0 \(testProcessID) 2>/dev/null && [ -d "\(directory.path)" ] && [ "$remaining" -gt 0 ]; do remaining=$((remaining - 1)); sleep 0.2; done' &
                    child=$!
                    trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null' 0
                    remaining=2400
                    while kill -0 \(testProcessID) 2>/dev/null && [ -d "\(directory.path)" ] && [ ! -f "\(quitFile.path)" ] && [ "$remaining" -gt 0 ]; do
                      remaining=$((remaining - 1))
                      sleep 0.05
                    done
                    if [ -f "\(quitFile.path)" ]; then
                      trap - 0
                      exit 0
                    fi
                    exit 124
                    """,
                ],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )
        // spawn 直後に所有する。以降の #require や保存が失敗してもリークさせない。
        let cleanup = TestProcessGroupCleanup(spawned)

        _ = try #require(
            await waitForValue {
                ProcessInspector.identity(pid: spawned.pid, workingDirectory: directory)
            }
        )
        // 孫が生まれてから錨を記録する。
        #expect(await waitForCondition {
            guard case let .members(members) =
                ProcessInspector.processGroupState(spawned.processGroupID)
            else { return false }
            return members.filter { !$0.isZombie }.count >= 2
        })

        let hint = try #require(
            makeMeasuredHint(
                project: project,
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                directory: directory
            )
        )
        try RuntimeHintStore(directory: directory).save([hint])

        // 本体が生きている間に照合し、引き継ぎ候補として提示させる。
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        #expect(presentation.review.candidates.map(\.hint.serviceID) == [hint.serviceID])

        // ここから先、引き継ぎは同一性不一致で失敗する。
        try Data("quit".utf8).write(to: quitFile)
        for _ in 0..<400 {
            if ProcessInspector.startAbstime(pid: spawned.pid) == nil { break }
            var status: Int32 = 0
            _ = waitpid(spawned.pid, &status, WNOHANG)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ProcessInspector.startAbstime(pid: spawned.pid) == nil)

        return (presentation.id, hint, spawned.processGroupID, cleanup)
    }

    // MARK: - 失敗した候補の手掛かり

    @Test("引き継ぎに失敗しても、残っているプロセスの手掛かりを失わない")
    func failedAdoptionKeepsHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        let race = try await presentRaceCondition(
            state: state,
            project: project,
            directory: directory
        )
        defer { #expect(race.cleanup.cleanUp()) }
        state.performHandoffAction(.adopt, presentationID: race.presentationID)
        await state.waitForPendingOperation()

        #expect(state.operationError != nil)

        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(
            stored.hints.contains { $0.serviceID == race.hint.serviceID },
            "失敗した候補の手掛かりが空の一覧で上書きされた"
        )

        let presented = try #require(state.handoffPresentation)
        #expect(presented.review.candidates.isEmpty)
        #expect(presented.review.stoppable.contains { $0.hint.serviceID == race.hint.serviceID })
    }

    @Test("停止に失敗しても、残っているプロセスの手掛かりを失わない")
    func failedStopKeepsHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        let race = try await presentRaceCondition(
            state: state,
            project: project,
            directory: directory
        )
        defer { #expect(race.cleanup.cleanUp()) }
        state.performHandoffAction(.stopAll, presentationID: race.presentationID)
        await state.waitForPendingOperation()

        #expect(state.operationError != nil)
        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(stored.hints.contains { $0.serviceID == race.hint.serviceID })

        let presented = try #require(state.handoffPresentation)
        #expect(presented.review.stoppable.contains { $0.hint.serviceID == race.hint.serviceID })
    }

    @Test("シートを表示したまま失敗しても、再提示が取り消されない")
    func representationSurvivesFastFailureWhileSheetIsShown() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        let race = try await presentRaceCondition(
            state: state,
            project: project,
            directory: directory
        )
        defer { #expect(race.cleanup.cleanUp()) }
        state.performHandoffAction(.adopt, presentationID: race.presentationID)
        await state.waitForPendingOperation()

        let presented = try #require(state.handoffPresentation)
        #expect(presented.id != race.presentationID)
        #expect(presented.resolution == .awaiting)
        #expect(presented.review.stoppable.contains { $0.hint.serviceID == race.hint.serviceID })
    }

    @Test("再提示された残存グループを停止できる")
    func canStopRepresentedResidualGroup() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        let race = try await presentRaceCondition(
            state: state,
            project: project,
            directory: directory
        )
        defer { #expect(race.cleanup.cleanUp()) }
        state.performHandoffAction(.adopt, presentationID: race.presentationID)
        await state.waitForPendingOperation()

        let presented = try #require(state.handoffPresentation)
        state.performHandoffAction(.stopAll, presentationID: presented.id)
        await state.waitForPendingOperation()

        #expect(ProcessInspector.processGroupState(race.processGroupID).hasLiveMembers == false)
        #expect(try RuntimeHintStore(directory: directory).load().isEmpty)
        #expect(state.handoffPresentation == nil)
    }

    @Test("プロセスが確実に消えているhintはモーダルを出さず自動整理する")
    func vanishedProcessHintIsDiscardedAutomatically() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        // 実在しないプロセスを指す手掛かり。
        let hint = RuntimeHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            serviceName: project.services[0].name,
            processGroupID: 999_999,
            leader: ProcessAnchor(pid: 999_999, startAbstime: 1),
            groupEvidence: ProcessGroupEvidence(
                bootSessionID: ProcessInspector.bootSessionID() ?? "unknown",
                anchors: [ProcessAnchor(pid: 999_999, startAbstime: 1)]
            ),
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            observedPorts: .observed([])
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])

        let state = makeAppState(
            directory: directory,
            handoffInspector: HandoffInspector(
                startAbstimeProbe: { _ in .notPresent },
                startTimeProbe: { _ in nil },
                executablePathProbe: { _ in nil },
                workingDirectoryProbe: { _ in nil },
                portProbe: { _ in [] },
                groupStateProbe: { _ in .members([]) },
                bootSessionProbe: { hint.groupEvidence.bootSessionID }
            )
        )
        state.loadProjects()
        await state.reviewHandoffCandidates()

        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().isEmpty)
    }

    @Test("消滅済みhintと定義欠落hintが混在すると定義欠落だけを保持して提示する")
    func processGoneAndDefinitionMissingKeepsOnlyMissingDefinition() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let gone = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        let missing = makeStoredHint(
            projectID: UUID(),
            serviceID: UUID(),
            serviceName: "Missing",
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([gone, missing])

        let state = makeAppState(
            directory: directory,
            handoffInspector: HandoffInspector(
                startAbstimeProbe: { _ in .notPresent },
                startTimeProbe: { _ in nil },
                executablePathProbe: { _ in nil },
                workingDirectoryProbe: { _ in nil },
                portProbe: { _ in [] },
                groupStateProbe: { _ in .members([]) },
                bootSessionProbe: { "TEST-BOOT-SESSION" }
            )
        )
        await state.bootstrap()

        let presented = try #require(state.handoffPresentation)
        #expect(presented.review.rejected.count == 1)
        guard case .definitionMissing = presented.review.rejected[0].reason else {
            Issue.record("定義欠落だけが提示されなかった")
            return
        }
        #expect(try hintStore.load().hints == [missing])
    }

    @Test("消滅済みhintの自動整理でもRegistry管理中のhintを消さない")
    func automaticCleanupKeepsManagedStackHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Managed", "Gone"]
        )
        try ProjectStore(directory: directory).save([project])
        let managed = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            serviceName: project.services[0].name,
            pid: 41_001,
            startAbstime: 101,
            directory: directory
        )
        let gone = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[1].id,
            serviceName: project.services[1].name,
            pid: 41_002,
            startAbstime: 102,
            directory: directory
        )
        let observations = ProcessObservationControl(
            startObservations: [managed.leader.pid: .present(managed.leader.startAbstime)],
            groupStates: [
                managed.processGroupID: .members([
                    ProcessInspector.ProcessGroupMember(
                        pid: managed.leader.pid,
                        isZombie: false
                    ),
                ]),
                gone.processGroupID: .members([]),
            ]
        )
        let registry = makeRegistry(directory: directory, observations: observations)
        try await registry.adopt(
            candidate: makeCandidate(for: managed),
            service: project.services[0],
            in: project
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([gone])
        let inspector = HandoffInspector(
            startAbstimeProbe: { observations.startObservation(pid: $0) },
            startTimeProbe: { _ in nil },
            executablePathProbe: { _ in nil },
            workingDirectoryProbe: { _ in nil },
            portProbe: { _ in [] },
            groupStateProbe: { observations.groupState(processGroupID: $0) },
            bootSessionProbe: { observations.bootSession() }
        )
        let state = makeAppState(
            directory: directory,
            registry: registry,
            handoffInspector: inspector
        )

        await state.bootstrap()

        #expect(state.handoffPresentation == nil)
        let stored = try hintStore.load().hints
        #expect(stored.count == 1)
        #expect(stored.first?.serviceID == managed.serviceID)
    }

    @Test("無視は未決着hintだけを削除し、保存失敗時はファイルとシートを変更しない")
    func ignoreKeepsManagedHintAndIsTransactional() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Managed", "Pending"]
        )
        try ProjectStore(directory: directory).save([project])
        let managed = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            serviceName: project.services[0].name,
            pid: 42_001,
            startAbstime: 201,
            directory: directory
        )
        let pending = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[1].id,
            serviceName: project.services[1].name,
            pid: 42_002,
            startAbstime: 202,
            directory: directory
        )
        let observations = ProcessObservationControl(
            startObservations: [
                managed.leader.pid: .present(managed.leader.startAbstime),
                // 観測できないので決着させられない。捨ててよいとも判断できない。
                pending.leader.pid: .unavailable(errno: EPERM),
            ],
            groupStates: [
                managed.processGroupID: .members([
                    ProcessInspector.ProcessGroupMember(
                        pid: managed.leader.pid,
                        isZombie: false
                    ),
                ]),
                pending.processGroupID: .unavailable(errno: EPERM),
            ]
        )
        let registry = makeRegistry(directory: directory, observations: observations)
        let hintStore = ControllableHintStore(directory: directory)
        try hintStore.save([managed, pending], legacy: [])
        let inspector = HandoffInspector(
            startAbstimeProbe: { observations.startObservation(pid: $0) },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in [] },
            groupStateProbe: { observations.groupState(processGroupID: $0) },
            bootSessionProbe: { observations.bootSession() }
        )
        let state = makeAppState(
            directory: directory,
            registry: registry,
            handoffInspector: inspector,
            hintStore: hintStore
        )
        state.loadProjects()
        await state.reviewHandoffCandidates()

        let firstPresentation = try #require(state.handoffPresentation)
        #expect(firstPresentation.review.candidates.map(\.hint.serviceID) == [managed.serviceID])
        state.performHandoffAction(.adopt, presentationID: firstPresentation.id)
        await state.waitForPendingOperation()

        // 引き継げた側は Registry 管理下、観測できない側は未決着のまま残る。
        #expect(await registry.isRunning(serviceID: managed.serviceID))
        let pendingPresentation = try #require(state.handoffPresentation)
        #expect(Set(try hintStore.load().hints.map(\.serviceID)) == [managed.serviceID, pending.serviceID])

        hintStore.failAllSaves()
        state.performHandoffAction(.ignore, presentationID: pendingPresentation.id)
        await state.waitForPendingOperation()

        // 破棄できなければ、ファイルもシートも変えない。同じ判断をやり直せる。
        #expect(state.handoffPresentation?.id == pendingPresentation.id)
        #expect(state.handoffPresentation?.resolution == .awaiting)
        #expect(Set(try hintStore.load().hints.map(\.serviceID)) == [managed.serviceID, pending.serviceID])

        hintStore.allowSaves()
        state.performHandoffAction(.ignore, presentationID: pendingPresentation.id)
        await state.waitForPendingOperation()

        #expect(state.handoffPresentation == nil)
        let remaining = try hintStore.load().hints
        #expect(remaining.count == 1)
        #expect(remaining.first?.serviceID == managed.serviceID)
    }

    @Test("ProjectStoreを読めない間はhintをレビューせず終了時にも保持する")
    func projectDecodeFailureKeepsHintThroughBootstrapAndFlush() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hintStore = RuntimeHintStore(directory: directory)
        let hint = makeStoredHint(
            projectID: UUID(),
            serviceID: UUID(),
            directory: directory
        )
        try hintStore.save([hint])
        try Data("{ broken projects json".utf8).write(
            to: ProjectStore(directory: directory).fileURL
        )

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        #expect(state.storeError != nil)
        #expect(state.handoffPresentation == nil)
        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(try hintStore.load().hints == [hint])
    }

    @Test("ProjectStoreの再読み込み成功後に同じAppStateでhintレビューを再開する")
    func retryingProjectLoadResumesHandoffReview() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let hintStore = RuntimeHintStore(directory: directory)
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try hintStore.save([hint])
        let projectStore = ProjectStore(directory: directory)
        try Data("{ broken projects json".utf8).write(to: projectStore.fileURL)

        let inspector = HandoffInspector(
            startAbstimeProbe: { _ in .unavailable(errno: EPERM) },
            startTimeProbe: { _ in nil },
            executablePathProbe: { _ in nil },
            workingDirectoryProbe: { _ in nil },
            portProbe: { _ in [] },
            groupStateProbe: { _ in .unavailable(errno: EPERM) },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )
        let state = makeAppState(directory: directory, handoffInspector: inspector)
        await state.bootstrap()

        #expect(state.storeError != nil)
        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().hints == [hint])

        try projectStore.save([project])
        await state.retryLoadingProjects()

        #expect(state.storeError == nil)
        let rejection = try #require(state.handoffPresentation?.review.rejected.first)
        guard case .groupUnobservable = rejection.reason else {
            Issue.record("再読み込み後に未解決hintが提示されなかった: \(rejection.reason)")
            return
        }
    }

    @Test("終了処理中はProjectStoreの再読み込みとhintレビューを開始しない")
    func terminationBlocksProjectLoadRetry() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])
        let projectStore = ProjectStore(directory: directory)
        try Data("{ broken projects json".utf8).write(to: projectStore.fileURL)

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        #expect(await state.flushRuntimeHintsBeforeTermination())

        try projectStore.save([project])
        await state.retryLoadingProjects()

        #expect(state.projects.isEmpty)
        #expect(state.storeError != nil)
        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().hints == [hint])
    }

    @Test("錨を読み取れない場合は観測不能としてAppStateのhintを保持する")
    func unreadableAnchorKeepsHintThroughAppState() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])
        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector()
        )
        await state.bootstrap()

        let rejection = try #require(state.handoffPresentation?.review.rejected.first)
        guard case .groupUnobservable = rejection.reason else {
            Issue.record("観測不能として提示されなかった: \(rejection.reason)")
            return
        }
        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(try hintStore.load().hints == [hint])
    }

    /// 観測できないので決着させられない手掛かりを作る。判断待ちの状態を作るために使う。
    private func makeUnobservableInspector() -> HandoffInspector {
        HandoffInspector(
            startAbstimeProbe: { _ in .unavailable(errno: EPERM) },
            startTimeProbe: { _ in nil },
            executablePathProbe: { _ in nil },
            workingDirectoryProbe: { _ in nil },
            portProbe: { _ in [] },
            groupStateProbe: { _ in
                .members([
                    ProcessInspector.ProcessGroupMember(pid: 999_999, isZombie: false),
                ])
            },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )
    }

    @Test("プロジェクト定義を削除してもhintを終了時まで保持する")
    func deletedProjectKeepsHintThroughBootstrapAndFlush() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let removedProject = makeWorkerProject(directory: directory)
        let hint = makeStoredHint(
            projectID: removedProject.id,
            serviceID: removedProject.services[0].id,
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])
        try ProjectStore(directory: directory).save([])

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        let rejection = try #require(state.handoffPresentation?.review.rejected.first)
        guard case .definitionMissing = rejection.reason else {
            Issue.record("定義欠落として提示されなかった: \(rejection.reason)")
            return
        }
        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(try hintStore.load().hints == [hint])
    }

    @Test("サービス定義を削除してもhintを終了時まで保持する")
    func deletedServiceKeepsHintThroughBootstrapAndFlush() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = makeWorkerProject(
            directory: directory,
            serviceNames: ["Keep", "Removed"]
        )
        let removedService = original.services[1]
        let remaining = ProjectDefinition(
            id: original.id,
            name: original.name,
            color: original.color,
            directory: original.workingDirectories[0].directory,
            services: [original.services[0]]
        )
        let hint = makeStoredHint(
            projectID: original.id,
            serviceID: removedService.id,
            serviceName: removedService.name,
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])
        try ProjectStore(directory: directory).save([remaining])

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        let rejection = try #require(state.handoffPresentation?.review.rejected.first)
        guard case .definitionMissing = rejection.reason else {
            Issue.record("定義欠落として提示されなかった: \(rejection.reason)")
            return
        }
        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(try hintStore.load().hints == [hint])
    }

    // MARK: - 排他と起動許可

    @Test("既存プロセスの照合中は起動も設定変更も受け付けない")
    func handoffReviewBlocksStartAndConfiguration() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        // 照合を portProbe で止める。ここが終わるまで判断は確定していない。
        let gate = TestGate()
        let inspector = HandoffInspector(
            startAbstimeProbe: { fixture.observations.startObservation(pid: $0) },
            startTimeProbe: { _ in 1_000_000 },
            executablePathProbe: { _ in "/bin/sleep" },
            workingDirectoryProbe: { _ in directory },
            portProbe: { _ in
                await gate.markReached()
                await gate.waitForRelease()
                return []
            },
            groupStateProbe: { fixture.observations.groupState(processGroupID: $0) },
            bootSessionProbe: { fixture.observations.bootSession() }
        )
        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: inspector
        )
        state.loadProjects()
        // 環境は取得済みにする。止めているのが環境ではないことを確かめる。
        await state.loadEnvironment()
        #expect(state.canStartServices)

        let reviewTask = Task { await state.reviewHandoffCandidates() }
        #expect(await gate.waitUntilReached())

        #expect(state.canStart == false)
        #expect(state.canEdit(fixture.project) == false)
        #expect(state.canChangeConfiguration == false)
        #expect(state.startBlockedReason?.contains("再検証") == true)

        // ポートを持たない worker なので、ゲートでは重複を検出できない。
        // ここで起動できてしまうと、同じ worker が2つ動く。
        state.startOrSwitch(to: fixture.project)
        #expect(await fixture.registry.occupyingServiceIDs(projectID: fixture.project.id).isEmpty)
        #expect(state.state(of: fixture.service.id).processID == nil)

        await gate.release()
        await reviewTask.value
        #expect(state.handoffPresentation != nil)
    }

    @Test("bootstrap の実行中は、ほかの再検証・再読み込みを同時に始めない")
    func bootstrapExcludesConcurrentReconciliation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        // bootstrap 側は定義を読めないまま止まる。ここで別経路が走ると、
        // 同じ手掛かりを2つの処理が同時に読み書きする。
        try Data("{ broken projects json".utf8).write(to: projectStore.fileURL)
        try RuntimeHintStore(directory: directory).save([
            makeStoredHint(
                projectID: project.id,
                serviceID: project.services[0].id,
                directory: directory
            ),
        ])

        let gate = TestGate()
        let state = makeAppState(
            directory: directory,
            environmentLoader: {
                await gate.markReached()
                await gate.waitForRelease()
                return fixedShellEnvironment
            },
            handoffInspector: makeUnobservableInspector()
        )

        let bootstrapTask = Task { await state.bootstrap() }
        #expect(await gate.waitUntilReached())

        try projectStore.save([project])
        await state.retryLoadingProjects()
        await state.reviewHandoffCandidates()
        await state.retryLoadingHints()

        // どれも開始しない。bootstrap が排他を握っている。
        #expect(state.projects.isEmpty)
        #expect(state.storeError != nil)
        #expect(state.handoffPresentation == nil)

        await gate.release()
        await bootstrapTask.value

        // 解放後は再開できる。
        await state.retryLoadingProjects()
        #expect(state.projects == [project])
        #expect(state.handoffPresentation != nil)
    }

    @Test("引き継ぎの判断待ち中は通常の起動・停止・設定変更を受け付けない")
    func pendingHandoffDecisionBlocksNormalOperations() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try RuntimeHintStore(directory: directory).save([hint])

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector()
        )
        await state.bootstrap()
        #expect(state.handoffPresentation != nil)
        #expect(state.canStartServices)

        #expect(state.canStart == false)
        #expect(state.startBlockedReason?.contains("既存プロセス") == true)
        // 停止は起動時確認の「停止する」へ導線を一本化する。
        #expect(state.canStop == false)
        #expect(state.stopBlockedReason?.contains("停止する") == true)
        #expect(state.canEdit(project) == false)

        state.startOrSwitch(to: project)
        #expect(state.isOperationInFlight == false)
        #expect(state.state(of: project.services[0].id).processID == nil)

        // 設定変更も拒否する。稼働中サービスのポート・コマンドと同じ理由で、
        // 決着していない実プロセスと定義がずれる。
        state.setEnabledNow(false, for: project.services[0], in: project)
        #expect(state.project(project.id)?.isEnabledNow(project.services[0].id) == true)
        #expect(state.operationError?.contains("既存プロセス") == true)

        #expect(throws: AppError.self) {
            try state.addProject(makeWorkerProject(name: "Another", directory: directory))
        }
        #expect(state.projects.count == 1)

        state.presentProjectForm(editing: project)
        #expect(state.projectFormPresentation == nil)
    }

    @Test("壊れた手掛かりファイルを読める状態に戻すまで、ポートなしサービスを起動しない")
    func brokenHintFileBlocksStartUntilResolved() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = RuntimeHintStore(directory: directory)
        try Data("{ not json".utf8).write(to: hintStore.fileURL)

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector()
        )
        await state.bootstrap()

        // 読み込めない間は起動しない。起動しても手掛かりを残せない。
        #expect(state.canStart == false)
        #expect(state.startBlockedReason?.contains("読み込めません") == true)
        state.startOrSwitch(to: project)
        #expect(state.state(of: project.services[0].id).processID == nil)
        #expect(state.phase(of: project) == .stopped)

        // ファイルを直しても、決着していない手掛かりが残る間は起動しない。
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try hintStore.save([hint])
        await state.retryLoadingHints()

        #expect(state.hintError == nil)
        let presentation = try #require(state.handoffPresentation)
        #expect(state.canStart == false)

        state.performHandoffAction(.ignore, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.handoffPresentation == nil)
        #expect(state.canStart)
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }
        #expect(state.operationError == nil)
        #expect(await waitForCondition {
            state.state(of: project.services[0].id).phase == .healthy
        })
    }

    @Test("終了を待っている間の再試行は保存先も読み込み状態も変えない")
    func retryDuringTerminationDoesNotTouchHintState() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let attempts = AttemptCounter()
        let gate = TestGate()
        let state = AppState(
            registry: RuntimeRegistry(
                portPollInterval: .seconds(60),
                logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                environmentLoader: {
                    await gate.markReached()
                    await gate.waitForRelease()
                    return fixedShellEnvironment
                }
            ),
            projectStoreFactory: { ProjectStore(directory: directory) },
            hintStoreFactory: {
                _ = attempts.next()
                throw TestFactoryError.unavailable
            }
        )
        #expect(attempts.count == 1)
        #expect(state.hintError != nil)

        let bootstrapTask = Task { await state.bootstrap() }
        #expect(await gate.waitUntilReached())

        // ⌘Q の待ち合わせ中。ここで factory を作り直すと、終了直前の保存と競合する。
        let flushTask = Task {
            await state.flushRuntimeHintsBeforeTermination(waitingUpTo: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await state.retryLoadingHints()
        #expect(attempts.count == 1)
        #expect(state.ensureHintsLoaded() == false)

        await gate.release()
        // 手掛かりを読めないので終了は許可しない。
        #expect(await flushTask.value == false)
        await bootstrapTask.value
        #expect(state.isTerminating == false)
    }

    // MARK: - 設定の保存境界

    @Test("プロジェクト設定を読み込めない間は、追加・更新・起動を受け付けず設定ファイルも書き換えない")
    func unreadableProjectStoreBlocksConfigurationAndStart() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        let broken = "{ broken projects json"
        try Data(broken.utf8).write(to: projectStore.fileURL)
        let originalData = try Data(contentsOf: projectStore.fileURL)

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        #expect(state.storeError != nil)
        #expect(state.projects.isEmpty)
        #expect(state.canStart == false)
        #expect(state.startBlockedReason?.contains("プロジェクト設定を読み込めません") == true)
        #expect(state.canChangeConfiguration == false)

        // 読めていない一覧を土台に保存すると、既存の定義をまるごと失う。
        #expect(throws: AppError.self) { try state.addProject(project) }
        #expect(throws: AppError.self) { try state.updateProject(project) }
        state.presentProjectForm()
        #expect(state.projectFormPresentation == nil)
        state.presentProjectForm(editing: project)
        #expect(state.projectFormPresentation == nil)

        state.startOrSwitch(to: project)
        #expect(state.isOperationInFlight == false)
        #expect(state.state(of: project.services[0].id).processID == nil)

        #expect(state.projects.isEmpty)
        #expect(try Data(contentsOf: projectStore.fileURL) == originalData)
    }

    @Test("読み込み済みの設定が再読み込みで壊れたら、古いメモリ内容で保存も起動もしない")
    func failedReloadKeepsStaleProjectsOutOfDisk() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        try projectStore.save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        #expect(state.canStart)
        #expect(state.canEdit(project))

        // 別の書き換えや障害でファイルが読めなくなった状態。
        let broken = "{ broken projects json"
        try Data(broken.utf8).write(to: projectStore.fileURL)
        let originalData = try Data(contentsOf: projectStore.fileURL)
        #expect(state.loadProjects() == false)

        // メモリには古い定義が残るが、それがディスクの最新とは限らない。
        #expect(state.projects == [project])
        #expect(state.canStart == false)
        #expect(state.canEdit(project) == false)

        let renamed = ProjectDefinition(
            id: project.id,
            name: "Renamed",
            color: project.color,
            directory: project.workingDirectories[0].directory,
            services: project.services
        )
        #expect(throws: AppError.self) { try state.updateProject(renamed) }
        state.setEnabledNow(false, for: project.services[0], in: project)
        state.startOrSwitch(to: project)
        #expect(state.isOperationInFlight == false)
        #expect(state.state(of: project.services[0].id).processID == nil)

        #expect(state.projects == [project])
        #expect(try Data(contentsOf: projectStore.fileURL) == originalData)
    }

    /// 引き継ぎ経由で稼働中の状態を作る。実プロセスを起動しないので、
    /// プロセス観測の権限に依存せず `phase.isActive` を前提にした検証ができる。
    private func adoptRunningService(
        state: AppState,
        fixture: SyntheticFixture
    ) async throws {
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        state.performHandoffAction(.adopt, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(state.phase(of: fixture.project) == .running)
    }

    @Test("引き継いだ稼働中サービスは、API境界でも定義と起動対象を変更できない")
    func adoptedRuntimeRejectsDirectMutation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        try projectStore.save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        try await adoptRunningService(state: state, fixture: fixture)

        let originalData = try Data(contentsOf: projectStore.fileURL)
        let renamed = ProjectDefinition(
            id: fixture.project.id,
            name: "Renamed",
            color: fixture.project.color,
            directory: fixture.project.workingDirectories[0].directory,
            services: fixture.project.services
        )

        // UI の無効化だけでは、ゲートが見る設定ポートと実測のずれを防げない。
        #expect(throws: AppError.self) { try state.updateProject(renamed) }
        state.setEnabledNow(false, for: fixture.service, in: fixture.project)
        #expect(state.operationError?.contains("動作中のプロセス") == true)
        state.resetEnabledNow(in: fixture.project)
        state.presentProjectForm(editing: fixture.project)
        #expect(state.projectFormPresentation == nil)

        #expect(state.project(fixture.project.id) == fixture.project)
        #expect(try Data(contentsOf: projectStore.fileURL) == originalData)

        state.stopProject(fixture.project)
        await state.waitForPendingOperation()
        #expect(state.phase(of: fixture.project) == .stopped)

        // 停止すれば同じ変更が通る。
        try state.updateProject(renamed)
        #expect(state.project(fixture.project.id)?.name == "Renamed")
        state.setEnabledNow(false, for: fixture.service, in: renamed)
        #expect(state.project(fixture.project.id)?.isEnabledNow(fixture.service.id) == false)
        #expect(try Data(contentsOf: projectStore.fileURL) != originalData)
    }

    @Test("引き継いだ稼働中サービスは、設定を読み込めなくなっても停止できる")
    func adoptedRuntimeCanBeStoppedWhenProjectStoreCannotBeRead() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        try projectStore.save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        try await adoptRunningService(state: state, fixture: fixture)

        try Data("{ broken projects json".utf8).write(to: projectStore.fileURL)
        #expect(state.loadProjects() == false)
        #expect(state.canChangeConfiguration == false)

        // 停止は復旧手段なので塞がない。塞ぐと画面からプロセスを止められなくなる。
        #expect(state.canStop)
        state.stopProject(fixture.project)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(state.phase(of: fixture.project) == .stopped)
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
    }

    @Test("実プロセスの稼働中でも、設定を読み込めなくなったら停止できる")
    func stopRemainsAvailableWhenProjectStoreCannotBeRead() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        try projectStore.save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }
        #expect(state.phase(of: project) == .running)

        try Data("{ broken projects json".utf8).write(to: projectStore.fileURL)
        #expect(state.loadProjects() == false)

        // 停止は復旧手段なので塞がない。塞ぐと画面からプロセスを止められなくなる。
        #expect(state.canStop)
        state.stopProject(project)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(state.phase(of: project) == .stopped)
    }

    @Test("実プロセスの稼働中は、API境界でも定義と起動対象を変更できない")
    func runningProjectRejectsDirectMutation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let projectStore = ProjectStore(directory: directory)
        try projectStore.save([project])
        let service = project.services[0]

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: service.id).processGroupID {
                kill(-group, SIGKILL)
            }
        }
        #expect(state.phase(of: project) == .running)

        let originalData = try Data(contentsOf: projectStore.fileURL)
        let renamed = ProjectDefinition(
            id: project.id,
            name: "Renamed",
            color: project.color,
            directory: project.workingDirectories[0].directory,
            services: project.services
        )

        // UI の無効化だけでは、ゲートが見る設定ポートと実測のずれを防げない。
        #expect(throws: AppError.self) { try state.updateProject(renamed) }
        state.setEnabledNow(false, for: service, in: project)
        #expect(state.operationError?.contains("動作中のプロセス") == true)
        state.resetEnabledNow(in: project)
        state.presentProjectForm(editing: project)
        #expect(state.projectFormPresentation == nil)

        #expect(state.project(project.id) == project)
        #expect(try Data(contentsOf: projectStore.fileURL) == originalData)

        state.stopProject(project)
        await state.waitForPendingOperation()
        #expect(state.phase(of: project) == .stopped)

        // 停止すれば同じ変更が通る。
        try state.updateProject(renamed)
        #expect(state.project(project.id)?.name == "Renamed")
        state.setEnabledNow(false, for: service, in: renamed)
        #expect(state.project(project.id)?.isEnabledNow(service.id) == false)
        #expect(try Data(contentsOf: projectStore.fileURL) != originalData)
    }

    // MARK: - 引き継ぎ操作の exactly-once

    @Test("引き継ぎ直後の停止・無視は受け付けない")
    func adoptRejectsFollowUpActions() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)

        state.performHandoffAction(.adopt, presentationID: presentation.id)
        // 実行中の2回目は副作用なしで拒否する。エラー表示も出さない。
        #expect(state.handoffPresentation?.resolution == .resolving(.adopt))
        state.performHandoffAction(.stopAll, presentationID: presentation.id)
        state.performHandoffAction(.ignore, presentationID: presentation.id)
        #expect(state.handoffPresentation?.resolution == .resolving(.adopt))
        #expect(state.operationError == nil)
        await state.waitForPendingOperation()

        #expect(fixture.signals.sent.isEmpty, "停止シグナルが送られた")
        #expect(await fixture.registry.isRunning(serviceID: fixture.service.id))
        #expect(state.handoffPresentation == nil)
        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(stored.hints.map(\.serviceID) == [fixture.hint.serviceID])
    }

    @Test("停止直後の引き継ぎは受け付けない")
    func stopAllRejectsFollowUpAdopt() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)

        state.performHandoffAction(.stopAll, presentationID: presentation.id)
        state.performHandoffAction(.adopt, presentationID: presentation.id)
        #expect(state.handoffPresentation?.resolution == .resolving(.stopAll))
        #expect(state.operationError == nil)
        await state.waitForPendingOperation()

        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
        #expect(await fixture.registry.isRunning(serviceID: fixture.service.id) == false)
        #expect(state.handoffPresentation == nil)
        #expect(try RuntimeHintStore(directory: directory).load().isEmpty)
    }

    @Test("決着済みの古い判断に対する操作は何も起こさない")
    func staleHandoffActionHasNoEffect() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let staleID = try #require(state.handoffPresentation?.id)

        state.performHandoffAction(.ignore, presentationID: staleID)
        await state.waitForPendingOperation()
        #expect(state.handoffPresentation == nil)
        #expect(try RuntimeHintStore(directory: directory).load().isEmpty)

        // 古い判断に対する操作は、引き継ぎも停止も始めない。
        state.performHandoffAction(.adopt, presentationID: staleID)
        #expect(state.isOperationInFlight == false)
        state.performHandoffAction(.stopAll, presentationID: staleID)
        #expect(state.isOperationInFlight == false)

        #expect(fixture.signals.sent.isEmpty)
        #expect(await fixture.registry.isRunning(serviceID: fixture.service.id) == false)
        #expect(state.handoffPresentation == nil)
        #expect(try RuntimeHintStore(directory: directory).load().isEmpty)
    }

    // MARK: - 旧形式からの移行

    /// v1 の記録を書く。安全な錨を持たないので、本体を確認できたときだけ変換できる。
    private func writeLegacyDocument(
        project: ProjectDefinition,
        pid: pid_t,
        startTimeMicroseconds: UInt64,
        directory: URL,
        to url: URL
    ) throws {
        let json = """
        {
          "schemaVersion" : 1,
          "hints" : [
            {
              "projectID" : "\(project.id.uuidString)",
              "serviceID" : "\(project.services[0].id.uuidString)",
              "serviceName" : "\(project.services[0].name)",
              "pid" : \(pid),
              "processGroupID" : \(pid),
              "startTimeMicroseconds" : \(startTimeMicroseconds),
              "executablePath" : "/bin/sleep",
              "workingDirectory" : "\(directory.absoluteString)",
              "observedPorts" : []
            }
          ]
        }
        """
        try Data(json.utf8).write(to: url)
    }

    @Test("移行の保存に失敗した後でも、引き継げば旧形式は再提示されない")
    func adoptAfterFailedMigrationDoesNotRepresentLegacyHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        let hintStore = ControllableHintStore(directory: directory)
        try writeLegacyDocument(
            project: fixture.project,
            pid: fixture.hint.leader.pid,
            startTimeMicroseconds: 1_000_000,
            directory: directory,
            to: hintStore.fileURL
        )

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector,
            hintStore: hintStore
        )
        state.loadProjects()

        // 移行後の保存に失敗する。画面には現行形式の候補が出るが、
        // ディスクとメモリには旧形式が残ったままになる。
        hintStore.failAllSaves()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        #expect(presentation.review.candidates.map(\.hint.serviceID) == [fixture.service.id])
        #expect(try hintStore.load().legacy.count == 1)

        hintStore.allowSaves()
        state.performHandoffAction(.adopt, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(await fixture.registry.isRunning(serviceID: fixture.service.id))
        // 決着したサービスが、旧形式から再変換されて出てこない。
        #expect(state.handoffPresentation == nil)
        #expect(state.canChangeConfiguration)
        let stored = try hintStore.load()
        #expect(stored.legacy.isEmpty)
        #expect(stored.hints.map(\.serviceID) == [fixture.service.id])
    }

    @Test("移行の保存に失敗した後でも、停止すれば旧形式ごと消える")
    func stopAfterFailedMigrationRemovesLegacyHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        let hintStore = ControllableHintStore(directory: directory)
        try writeLegacyDocument(
            project: fixture.project,
            pid: fixture.hint.leader.pid,
            startTimeMicroseconds: 1_000_000,
            directory: directory,
            to: hintStore.fileURL
        )

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector,
            hintStore: hintStore
        )
        state.loadProjects()

        hintStore.failAllSaves()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        hintStore.allowSaves()

        state.performHandoffAction(.stopAll, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().isEmpty)
        #expect(state.canChangeConfiguration)
    }

    // MARK: - 保存失敗の再試行

    @Test("管理中サービスだけの保存失敗は、再試行で完全スナップショットを書き直す")
    func retryResavesCompleteSnapshotForManagedRuntime() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        let hintStore = ControllableHintStore(directory: directory)
        try await fixture.registry.adopt(
            candidate: makeCandidate(for: fixture.hint),
            service: try #require(fixture.service.processDefinition),
            in: fixture.project
        )

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector,
            hintStore: hintStore
        )
        state.loadProjects()
        #expect(state.ensureHintsLoaded())

        // 未決着の手掛かりは無く、管理中サービスの保存だけが失敗している状態。
        hintStore.failAllSaves()
        await state.retryLoadingHints()
        #expect(state.hintError != nil)
        #expect(state.canStart == false)
        #expect(FileManager.default.fileExists(atPath: hintStore.fileURL.path) == false)

        hintStore.allowSaves()
        await state.retryLoadingHints()

        // 読み直すだけでは保存失敗が解消しない。完全なスナップショットを書き直す。
        #expect(state.hintError == nil)
        let stored = try hintStore.load()
        #expect(stored.hints.map(\.serviceID) == [fixture.service.id])
    }

    // MARK: - 起動前後の保存

    @Test("起動後の保存失敗では今回起動したSupabaseだけを停止し、引き継ぎ分を残す",
          arguments: [false, true])
    func unsavedSupabaseStartPreservesAdoption(adopting: Bool) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: adopting ? ["demo": .databaseHealthy] : [:])
        let hintStore = ControllableHintStore(directory: directory)
        let state = makeAppState(directory: directory, hintStore: hintStore, supabaseWorld: world)
        await state.bootstrap()

        if adopting {
            state.startOrSwitch(to: project)
            await state.waitForPendingOperation()
            let confirmation = try #require(state.managedStackConfirmation)
            let base = hintStore.saveAttempts
            hintStore.failSaves { $0 == base + 2 }
            state.approveManagedStackConfirmation(confirmation)
        } else {
            let base = hintStore.saveAttempts
            hintStore.failSaves { $0 == base + 2 }
            state.startOrSwitch(to: project)
        }
        await state.waitForPendingOperation()

        #expect(state.operationError != nil)
        #expect(await world.runningProjectIDs == (adopting ? ["demo"] : []))
        #expect(await world.commandLines.contains { $0.contains("stop") } == !adopting)
        #expect(state.phase(of: project) == (adopting ? .residual : .stopped))
        if adopting {
            let hint = try #require(hintStore.load().managed.first)
            #expect(hint.relationship == .adopted)
            #expect(state.hasManagedResources(in: project))
            state.stopProject(project)
            await state.waitForPendingOperation()
            #expect(await world.runningProjectIDs.isEmpty)
            #expect(try hintStore.load().managed.isEmpty)
        }
    }

    @Test("引き継ぎ後の保存失敗が続いてもSupabaseを維持し、保存再試行と明示停止ができる")
    func persistentSaveFailurePreservesAdoptedSupabase() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        let hintStore = ControllableHintStore(directory: directory)
        let state = makeAppState(directory: directory, hintStore: hintStore, supabaseWorld: world)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        let confirmation = try #require(state.managedStackConfirmation)
        let base = hintStore.saveAttempts
        hintStore.failSaves { $0 >= base + 2 }
        state.approveManagedStackConfirmation(confirmation)
        await state.waitForPendingOperation()

        #expect(state.phase(of: project) == .residual)
        #expect(state.hasManagedResources(in: project))
        #expect(state.hintError != nil)
        #expect(state.canStart == false)
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(await world.runningProjectIDs == ["demo"])
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })

        hintStore.allowSaves()
        await state.retryLoadingHints()
        #expect(state.hintError == nil)
        let hint = try #require(hintStore.load().managed.first)
        #expect(hint.relationship == .adopted)
        state.stopProject(project)
        await state.waitForPendingOperation()
        #expect(await world.runningProjectIDs.isEmpty)
        #expect(try hintStore.load().managed.isEmpty)
    }

    @Test("起動前に手掛かりを保存できなければ、プロセスを1つも起動しない")
    func startIsAbortedWhenPreSaveFails() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()
        #expect(state.canStart)

        hintStore.failAllSaves()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()

        #expect(state.operationError?.contains("起動を中止") == true)
        #expect(hintStore.saveAttempts == 1)
        #expect(state.state(of: project.services[0].id).processID == nil)
        #expect(state.phase(of: project) == .stopped)
        #expect(FileManager.default.fileExists(atPath: hintStore.fileURL.path) == false)
    }

    @Test("起動後に手掛かりを保存できなければ、今回起動した分を補償停止する")
    func failedFinalSaveCompensatesStartedProcesses() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()

        // 起動前の保存は成功させ、起動後の保存だけを失敗させる。
        let base = hintStore.saveAttempts
        hintStore.failSaves { $0 == base + 2 }
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        #expect(state.operationError?.contains("停止") == true)
        // 記録に無いプロセスを残さない。
        #expect(state.phase(of: project) == .stopped)
        #expect(state.state(of: project.services[0].id).processID == nil)
        #expect(try hintStore.load().isEmpty)
    }

    @Test("切替前に手掛かりを保存できなければ、切替元を停止しない")
    func switchIsAbortedWhenPreSaveFails() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = makeWorkerProject(name: "Demo", directory: directory)
        let target = makeWorkerProject(name: "Sample", directory: directory)
        try ProjectStore(directory: directory).save([source, target])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()
        state.startOrSwitch(to: source)
        await state.waitForPendingOperation()
        defer {
            for service in source.services + target.services {
                if let group = state.state(of: service.id).processGroupID {
                    kill(-group, SIGKILL)
                }
            }
        }
        #expect(state.phase(of: source) == .running)

        hintStore.failAllSaves()
        state.startOrSwitch(to: target)
        await state.waitForPendingOperation()

        #expect(state.operationError?.contains("起動を中止") == true)
        // 切替元は止めない。止めたうえで起動もできない状態を作らない。
        #expect(state.phase(of: source) == .running)
        #expect(state.state(of: source.services[0].id).phase == .healthy)
        #expect(state.state(of: target.services[0].id).processID == nil)
        #expect(state.phase(of: target) == .stopped)
    }

    @Test("切替後に手掛かりを保存できなければ、切替先を補償停止する")
    func failedFinalSaveAfterSwitchCompensatesTarget() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = makeWorkerProject(name: "Demo", directory: directory)
        let target = makeWorkerProject(name: "Sample", directory: directory)
        try ProjectStore(directory: directory).save([source, target])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()
        state.startOrSwitch(to: source)
        await state.waitForPendingOperation()
        defer {
            for service in source.services + target.services {
                if let group = state.state(of: service.id).processGroupID {
                    kill(-group, SIGKILL)
                }
            }
        }
        #expect(state.phase(of: source) == .running)

        let base = hintStore.saveAttempts
        hintStore.failSaves { $0 == base + 2 }
        state.startOrSwitch(to: target)
        await state.waitForPendingOperation()

        #expect(state.operationError?.contains("停止") == true)
        #expect(state.phase(of: source) == .stopped)
        #expect(state.phase(of: target) == .stopped)
        #expect(state.state(of: target.services[0].id).processID == nil)
        // 手掛かりに無いプロセスを残さない。
        #expect(try hintStore.load().isEmpty)
    }

    @Test("補償停止にも失敗したら残存として表示し、終了を許可しない")
    func failedCompensationKeepsResidualAndBlocksTermination() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // SIGTERM を無視するので、補償のための停止は失敗する。
        let testProcessID = getpid()
        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Stubborn"],
            arguments: [
                "-c",
                """
                trap "" TERM
                remaining=300
                while kill -0 \(testProcessID) 2>/dev/null && [ -d "\(directory.path)" ] && [ "$remaining" -gt 0 ]; do
                  remaining=$((remaining - 1))
                  sleep 0.2
                done
                """,
            ],
            executable: "/bin/sh"
        )
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(
            directory: directory,
            hintStore: hintStore,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .milliseconds(300),
                startupObservationWindow: .milliseconds(200),
                startupPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )
        await state.bootstrap()

        let base = hintStore.saveAttempts
        hintStore.failSaves { $0 >= base + 2 }
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        #expect(state.operationError?.contains("残っています") == true)
        #expect(state.failurePresentation != nil)
        #expect(state.phase(of: project) == .residual)
        // 手掛かりを保存できないまま終了させない。
        #expect(await state.flushRuntimeHintsBeforeTermination(waitingUpTo: .seconds(5)) == false)
        #expect(state.isTerminating == false)
    }

    // MARK: - 残存表示

    @Test("孫がポートを握ったまま残っている間は、実測ポートを消さない")
    func residualServiceKeepsObservedPorts() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let reserved = try LocalPortReservation()
        let port = reserved.port
        reserved.release()

        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Holder"],
            arguments: ["-c", "/usr/bin/nc -l \(port) & sleep 1; exit 0"],
            executable: "/bin/sh",
            ports: [PortSpec(port: port, isPrimary: true)]
        )
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        #expect(await waitForCondition {
            state.state(of: project.services[0].id).phase == .residual
        })

        let uiState = state.state(of: project.services[0].id)
        #expect(uiState.processID == nil)
        #expect(uiState.processGroupID != nil)
        #expect(uiState.observedPorts.map(\.port).contains(port))
        #expect(state.phase(of: project) == .residual)
    }

    @Test("再起動後に登録した残存グループのプロセスグループを表示する")
    func residualGroupFromHandoffIsDisplayed() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // SIGTERM を無視する孫を残して本体だけが終了する。
        let readyFile = directory.appendingPathComponent("ready")
        let releaseFile = directory.appendingPathComponent("release")
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "/bin/sh -c 'trap \"\" TERM; echo ready > \"\(readyFile.path)\";"
                        + " while true; do sleep 1; done' &"
                        + " while [ ! -f \"\(releaseFile.path)\" ]; do sleep 0.05; done; exit 0",
                ],
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

        _ = try #require(
            await waitForValue {
                ProcessInspector.identity(pid: spawned.pid, workingDirectory: directory)
            }
        )
        #expect(await waitForCondition { FileManager.default.fileExists(atPath: readyFile.path) })

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = try #require(
            makeMeasuredHint(
                project: project,
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                directory: directory
            )
        )
        try RuntimeHintStore(directory: directory).save([hint])
        try "go".write(to: releaseFile, atomically: true, encoding: .utf8)

        for _ in 0..<400 {
            if ProcessInspector.startAbstime(pid: spawned.pid) == nil { break }
            var status: Int32 = 0
            _ = waitpid(spawned.pid, &status, WNOHANG)
            try await Task.sleep(for: .milliseconds(10))
        }

        let state = makeAppState(directory: directory)
        state.loadProjects()
        await state.reviewHandoffCandidates()

        let presented = try #require(state.handoffPresentation)
        #expect(presented.review.stoppable.count == 1)

        // 「すべて停止」を選ぶが、孫が SIGTERM を無視するので停止しきれない。
        state.performHandoffAction(.stopAll, presentationID: presented.id)
        await state.waitForPendingOperation()

        #expect(state.operationError != nil)
        let uiState = state.state(of: project.services[0].id)
        #expect(uiState.phase == .residual)
        #expect(uiState.processID == nil)
        #expect(uiState.processGroupID == spawned.processGroupID)
    }

    @Test("引き継ぎに成功したら、手掛かりを実測から作り直す")
    func successfulAdoptionRewritesHintFromMeasurement() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["120"],
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

        _ = try #require(
            await waitForValue {
                ProcessInspector.identity(pid: spawned.pid, workingDirectory: directory)
            }
        )
        let hint = try #require(
            makeMeasuredHint(
                project: project,
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                directory: directory
            )
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        #expect(presentation.review.candidates.count == 1)

        state.performHandoffAction(.adopt, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        let stored = try hintStore.load()
        #expect(stored.hints.count == 1)
        #expect(stored.hints.first?.leader.pid == spawned.pid)

        let uiState = state.state(of: project.services[0].id)
        #expect(uiState.phase == .healthy)
        #expect(uiState.processID == spawned.pid)
        #expect(uiState.processGroupID == spawned.processGroupID)
    }

    // MARK: - 終了処理

    @Test("管理中サービスのhintを完全に観測できなければ終了保存を中止する")
    func terminationSnapshotFailureDoesNotOverwriteExistingHints() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let service = project.services[0]
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: service.id,
            serviceName: service.name,
            pid: 43_001,
            startAbstime: 301,
            directory: directory
        )
        let observations = ProcessObservationControl(
            startObservations: [hint.leader.pid: .present(hint.leader.startAbstime)],
            groupStates: [
                hint.processGroupID: .members([
                    ProcessInspector.ProcessGroupMember(pid: hint.leader.pid, isZombie: false),
                ]),
            ]
        )
        let registry = makeRegistry(directory: directory, observations: observations)
        try await registry.adopt(
            candidate: makeCandidate(for: hint),
            service: service,
            in: project
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])
        let originalData = try Data(contentsOf: hintStore.fileURL)
        let state = makeAppState(directory: directory, registry: registry)
        state.loadProjects()
        #expect(state.ensureHintsLoaded())

        observations.setBootSessionID(nil)
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(try Data(contentsOf: hintStore.fileURL) == originalData)
        #expect(state.hintError?.contains(service.name) == true)

        observations.setBootSessionID("TEST-BOOT-SESSION")
        observations.setStartObservation(.unavailable(errno: EPERM), for: hint.leader.pid)
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(try Data(contentsOf: hintStore.fileURL) == originalData)
        #expect(state.hintError?.contains(service.name) == true)
    }

    @Test("複数の管理中サービスのうち1件でもhint観測不能なら部分保存しない")
    func oneUnavailableRuntimePreventsPartialTerminationSnapshot() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Observable", "Unavailable"]
        )
        try ProjectStore(directory: directory).save([project])
        let hints = [
            makeStoredHint(
                projectID: project.id,
                serviceID: project.services[0].id,
                serviceName: project.services[0].name,
                pid: 44_001,
                startAbstime: 401,
                directory: directory
            ),
            makeStoredHint(
                projectID: project.id,
                serviceID: project.services[1].id,
                serviceName: project.services[1].name,
                pid: 44_002,
                startAbstime: 402,
                directory: directory
            ),
        ]
        let observations = ProcessObservationControl(
            startObservations: Dictionary(
                uniqueKeysWithValues: hints.map { ($0.leader.pid, .present($0.leader.startAbstime)) }
            ),
            groupStates: Dictionary(
                uniqueKeysWithValues: hints.map { hint in
                    (
                        hint.processGroupID,
                        .members([
                            ProcessInspector.ProcessGroupMember(
                                pid: hint.leader.pid,
                                isZombie: false
                            ),
                        ])
                    )
                }
            )
        )
        let registry = makeRegistry(directory: directory, observations: observations)
        for (service, hint) in zip(project.services, hints) {
            try await registry.adopt(
                candidate: makeCandidate(for: hint),
                service: service,
                in: project
            )
        }
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save(hints)
        let originalData = try Data(contentsOf: hintStore.fileURL)
        let state = makeAppState(directory: directory, registry: registry)
        state.loadProjects()
        #expect(state.ensureHintsLoaded())

        observations.setStartObservation(
            .unavailable(errno: EPERM),
            for: hints[1].leader.pid
        )
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(try Data(contentsOf: hintStore.fileURL) == originalData)
        #expect(state.hintError?.contains(project.services[1].name) == true)
    }

    @Test("終了時の書き出しは、進行中の起動が終わってから行う")
    func terminationFlushWaitsForRunningOperation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["First", "Second"]
        )
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(
            directory: directory,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .seconds(2),
                // サービスごとに観測時間がかかるので、起動は即座には終わらない。
                startupObservationWindow: .milliseconds(400),
                startupPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )
        await state.bootstrap()
        defer {
            for service in project.services {
                if let group = state.state(of: service.id).processGroupID {
                    kill(-group, SIGKILL)
                }
            }
        }

        state.startOrSwitch(to: project)
        #expect(state.isOperationInFlight)

        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(state.isOperationInFlight == false)

        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(stored.hints.count == project.services.count)
        for service in project.services {
            #expect(
                stored.hints.contains { $0.serviceID == service.id },
                "起動したサービス「\(service.name)」の手掛かりが書き出されていない"
            )
        }
    }

    @Test("起動直後に終了しても、既存の手掛かりを空の一覧で上書きしない")
    func terminationDuringBootstrapKeepsExistingHints() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try RuntimeHintStore(directory: directory).save([hint])

        // bootstrap の途中（環境取得）で止める。
        let gate = TestGate()
        let state = makeAppState(
            directory: directory,
            environmentLoader: {
                await gate.markReached()
                await gate.waitForRelease()
                return fixedShellEnvironment
            },
            handoffInspector: makeUnobservableInspector()
        )

        let bootstrapTask = Task { await state.bootstrap() }
        #expect(await gate.waitUntilReached())

        // ここで ⌘Q。bootstrap も排他の対象なので、待たない実装だと
        // 空の一覧を保存して既存の記録を失う。
        let flushTask = Task { await state.flushRuntimeHintsBeforeTermination() }
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()

        #expect(await flushTask.value)
        await bootstrapTask.value

        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(
            stored.hints.contains { $0.serviceID == hint.serviceID },
            "bootstrap の途中で終了したときに既存の手掛かりが消えた"
        )
    }

    @Test("引き継ぎの照合中に終了しても、手掛かりを失わない")
    func terminationDuringHandoffReviewKeepsHints() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try RuntimeHintStore(directory: directory).save([hint])

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector()
        )
        state.loadProjects()

        // 照合を開始し、その途中で終了要求を出す。
        let reviewTask = Task { await state.reviewHandoffCandidates() }
        let flushTask = Task { await state.flushRuntimeHintsBeforeTermination() }

        #expect(await flushTask.value)
        await reviewTask.value

        let stored = try RuntimeHintStore(directory: directory).load()
        #expect(
            stored.hints.contains { $0.serviceID == hint.serviceID },
            "照合中に終了したときに手掛かりが消えた"
        )
    }

    @Test("判断待ちのまま終了しても、未決着の手掛かりを含めて保存する")
    func terminationDuringPendingDecisionKeepsPendingHints() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([hint])

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector()
        )
        await state.bootstrap()
        let presentation = try #require(state.handoffPresentation)
        #expect(presentation.resolution == .awaiting)

        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(try hintStore.load().hints.map(\.serviceID) == [hint.serviceID])
        // 判断待ちのまま終了する。次回起動時に同じ判断をやり直す。
        #expect(state.handoffPresentation?.id == presentation.id)
    }

    @Test("終了時に書き出せなければ、判断画面へ戻って操作を再開できる")
    func failedTerminationSaveReturnsToPendingDecision() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)
        try hintStore.save(
            [
                makeStoredHint(
                    projectID: project.id,
                    serviceID: project.services[0].id,
                    directory: directory
                ),
            ],
            legacy: []
        )

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector(),
            hintStore: hintStore
        )
        await state.bootstrap()
        let presentation = try #require(state.handoffPresentation)

        hintStore.failAllSaves()
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(state.isTerminating == false)
        #expect(state.hintError != nil)

        // 終了要求の前の状態に戻り、同じ判断をやり直せる。
        #expect(state.handoffPresentation?.id == presentation.id)
        #expect(state.handoffPresentation?.resolution == .awaiting)

        hintStore.allowSaves()
        state.performHandoffAction(.ignore, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().isEmpty)
        #expect(await state.flushRuntimeHintsBeforeTermination())
    }

    @Test("終了直前の保存で、後から生まれた子孫の錨が手掛かりへ入る")
    func terminationFlushRecordsLateBornDescendants() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readyFile = directory.appendingPathComponent("late.ready")
        let testProcessID = getpid()
        // 起動してしばらくしてから子を作るサービス。
        let project = makeWorkerProject(
            directory: directory,
            serviceNames: ["Late"],
            arguments: [
                "-c",
                "sleep 0.4; /bin/sh -c 'remaining=600; while kill -0 \(testProcessID)"
                    + " 2>/dev/null && [ -d \"\(directory.path)\" ]"
                    + " && [ \"$remaining\" -gt 0 ];"
                    + " do remaining=$((remaining - 1)); sleep 0.2; done' &"
                    + " echo late > \"\(readyFile.path)\"; remaining=600;"
                    + " while kill -0 \(testProcessID) 2>/dev/null"
                    + " && [ -d \"\(directory.path)\" ] && [ \"$remaining\" -gt 0 ];"
                    + " do remaining=$((remaining - 1)); sleep 0.2; done",
            ],
            executable: "/bin/sh"
        )
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        #expect(await waitForCondition { FileManager.default.fileExists(atPath: readyFile.path) })
        let processGroupID = try #require(state.state(of: project.services[0].id).processGroupID)
        let liveMembers = try #require(
            ProcessInspector.processGroupMembers(processGroupID)?
                .filter { !$0.isZombie }
                .map(\.pid)
        )

        #expect(await state.flushRuntimeHintsBeforeTermination())

        let stored = try RuntimeHintStore(directory: directory).load()
        let hint = try #require(stored.hints.first { $0.serviceID == project.services[0].id })
        let anchoredPIDs = Set(hint.groupEvidence.anchors.map(\.pid))
        // 終了直前に測り直すので、後から生まれた子孫も錨に入る。
        // 入らないと、本体が終了したあとにグループを同定できず回収できない。
        #expect(anchoredPIDs.isSuperset(of: Set(liveMembers)))
        #expect(hint.groupEvidence.anchors.count >= 2)
    }

    @Test("変換できない旧形式は、AppState を通しても捨てずに持ち回る")
    func legacyHintSurvivesAppStateReviewAndFlush() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        // 本体が存在しない v1 の記録。安全な錨へ変換できない。
        let hintStore = RuntimeHintStore(directory: directory)
        try writeLegacyDocument(
            project: project,
            pid: 999_999,
            startTimeMicroseconds: 1_000_000,
            directory: directory,
            to: hintStore.fileURL
        )

        let state = makeAppState(directory: directory)
        state.loadProjects()
        await state.reviewHandoffCandidates()

        // 変換できないものは判断を求める対象として提示する。
        // 出さずに黙って持つと、利用者が「無視」を選ぶ機会が無くなる。
        let presented = try #require(state.handoffPresentation)
        #expect(presented.review.unresolvedRejections.count == 1)

        // 終了時の書き出しでも消えない。
        #expect(await state.flushRuntimeHintsBeforeTermination())
        let stored = try hintStore.load()
        #expect(
            stored.legacy.contains { $0.serviceID == project.services[0].id },
            "変換できない旧形式が AppState 経路で消えた"
        )
    }

    @Test("旧形式でも「無視」を選べば破棄する")
    func legacyHintIsDiscardedWhenIgnored() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let hintStore = RuntimeHintStore(directory: directory)
        try hintStore.save([], legacy: [
            LegacyRuntimeHint(
                projectID: project.id,
                serviceID: project.services[0].id,
                serviceName: project.services[0].name,
                pid: 999_999,
                processGroupID: 999_999,
                startTimeMicroseconds: 1_000_000,
                executablePath: "/bin/sleep",
                workingDirectory: directory,
                observedPorts: []
            ),
        ])

        let state = makeAppState(directory: directory)
        state.loadProjects()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)

        // 利用者が明示的に選んだときだけ消える。
        state.performHandoffAction(.ignore, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.handoffPresentation == nil)
        #expect(try hintStore.load().isEmpty)
    }

    @Test("手掛かりを読み込めなければ、終了を許可せず既存ファイルも上書きしない")
    func terminationIsCancelledWhenHintsCannotBeLoaded() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 壊れた内容を置く。読み込めない状態で保存すると、中身を失う。
        let hintStore = RuntimeHintStore(directory: directory)
        let brokenContent = "{ not json"
        try Data(brokenContent.utf8).write(to: hintStore.fileURL)

        let state = makeAppState(directory: directory)
        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(state.hintError != nil)
        #expect(state.isTerminating == false)

        // 読めなかったものを空の一覧で置き換えない。
        let content = try String(contentsOf: hintStore.fileURL, encoding: .utf8)
        #expect(content == brokenContent)
    }

    @Test("hint保存先の初期化を再試行するとfactoryを作り直す")
    func retryRecreatesUnavailableHintStore() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        try RuntimeHintStore(directory: directory).save([])
        let attempts = AttemptCounter()
        let state = AppState(
            registry: RuntimeRegistry(
                portPollInterval: .seconds(60),
                logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                environmentLoader: { fixedShellEnvironment }
            ),
            projectStoreFactory: { ProjectStore(directory: directory) },
            hintStoreFactory: {
                guard attempts.next() > 1 else { throw TestFactoryError.unavailable }
                return RuntimeHintStore(directory: directory)
            }
        )

        // hint側の初期化失敗と独立して、project側は利用できる。
        state.loadProjects()
        #expect(state.projects == [project])
        #expect(state.hintError != nil)

        await state.retryLoadingHints()

        #expect(attempts.count == 2)
        #expect(state.hintError == nil)
        #expect(state.ensureHintsLoaded())
    }

    @Test("終了処理に入ったら、新しい起動・停止・再検証を受け付けない")
    func terminationBlocksNewOperations() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        #expect(await state.flushRuntimeHintsBeforeTermination())
        #expect(state.isTerminating)
        #expect(state.canStart == false)
        #expect(state.canStop == false)
        #expect(state.canChangeConfiguration == false)

        state.startOrSwitch(to: project)
        #expect(state.isOperationInFlight == false)

        // 照合も始めない。手掛かりを読み書きするため、保存後に走らせない。
        await state.reviewHandoffCandidates()
        #expect(state.handoffPresentation == nil)
    }

    @Test("終了時に書き出せなければ、終了を許可しない")
    func terminationIsCancelledWhenSaveFails() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hintStore = ControllableHintStore(directory: directory)
        try hintStore.save([], legacy: [])
        let state = makeAppState(directory: directory, hintStore: hintStore)
        // 読み込みは成功させ、書き込みだけ失敗させる。
        #expect(state.ensureHintsLoaded())
        hintStore.failAllSaves()

        #expect(await state.flushRuntimeHintsBeforeTermination() == false)
        #expect(state.hintError != nil)
        #expect(state.isTerminating == false)
    }

    @Test("進行中の処理が終わらなければ、終了を許可しない")
    func terminationIsCancelledWhenActivityDoesNotFinish() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        // bootstrap を止めたまま、短い猶予で終了を要求する。
        let gate = TestGate()
        let state = makeAppState(
            directory: directory,
            environmentLoader: {
                await gate.markReached()
                await gate.waitForRelease()
                return fixedShellEnvironment
            }
        )

        let bootstrapTask = Task { await state.bootstrap() }
        #expect(await gate.waitUntilReached())

        #expect(
            await state.flushRuntimeHintsBeforeTermination(waitingUpTo: .milliseconds(200)) == false
        )
        #expect(state.operationError != nil)
        #expect(state.isTerminating == false)

        await gate.release()
        await bootstrapTask.value
    }

    @Test("手掛かりを破棄できなければ、無視の操作を成功として扱わない")
    func failedDiscardIsReported() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)
        let hint = makeStoredHint(
            projectID: project.id,
            serviceID: project.services[0].id,
            directory: directory
        )
        try hintStore.save([hint], legacy: [])

        let state = makeAppState(
            directory: directory,
            handoffInspector: makeUnobservableInspector(),
            hintStore: hintStore
        )
        await state.bootstrap()
        let presentation = try #require(state.handoffPresentation)

        hintStore.failAllSaves()
        state.performHandoffAction(.ignore, presentationID: presentation.id)
        await state.waitForPendingOperation()

        #expect(state.hintError != nil)
        // 成功したかのようにシートを閉じない。
        #expect(state.handoffPresentation?.id == presentation.id)
        #expect(state.handoffPresentation?.resolution == .awaiting)
        #expect(try hintStore.load().hints.map(\.serviceID) == [hint.serviceID])
    }

    @Test("テストは利用者の Application Support へ書き込まない")
    func doesNotWriteToApplicationSupport() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 直下だけでなく、ログの置き場まで含めて見る。
        // logs/ の中に増えるとディレクトリ一覧では気づけない。
        let applicationSupport = try ApplicationPaths.applicationSupportDirectory()
        func snapshot() throws -> [String] {
            let enumerator = FileManager.default.enumerator(atPath: applicationSupport.path)
            var entries: [String] = []
            while let entry = enumerator?.nextObject() as? String {
                entries.append(entry)
            }
            return entries.sorted()
        }
        let before = try snapshot()

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }
        _ = await state.flushRuntimeHintsBeforeTermination()

        // ログも設定も手掛かりも、すべて一時ディレクトリ側にある。
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("logs").path))
        #expect(try snapshot() == before)
    }
}
