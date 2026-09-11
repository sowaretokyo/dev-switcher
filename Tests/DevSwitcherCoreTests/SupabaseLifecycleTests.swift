import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("Supabaseの起動・引き継ぎ・停止")
struct SupabaseLifecycleTests {
    private func makeStack(
        world: FakeSupabaseWorld,
        logDirectory: URL
    ) -> (RuntimeRegistry, SwitchCoordinator) {
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: logDirectory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in [] },
            supabaseController: SupabaseStackController(
                inventory: world,
                runner: world,
                options: SupabaseStackController.Options(
                    startConfirmationWindow: .milliseconds(300),
                    stopConfirmationWindow: .milliseconds(300),
                    pollInterval: .milliseconds(10)
                )
            )
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
        return (registry, coordinator)
    }

    private func makeSupabaseProject(
        name: String = "Bell",
        projectID: String = "bell",
        directory: URL,
        extraServices: [ServiceDefinition] = []
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: projectID, in: directory)
        return makeProject(
            name: name,
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)] + extraServices
        )
    }

    private func confirmationPlan(_ error: any Error) throws -> SupabaseConfirmationPlan {
        let failure = try #require(error as? SwitchFailure)
        guard case let .supabaseConfirmationRequired(plan) = failure.reason else {
            Issue.record("確認要求ではない失敗: \(failure.reason)")
            throw failure
        }
        return plan
    }

    // MARK: - 引き継ぎ

    enum StopConfirmation: CaseIterable {
        case stop, forceStop, observation, failedStop
    }

    @Test("停止確認で管理関係を解除し、同一IDが外部再起動しても停止権限を取り戻さない",
          arguments: StopConfirmation.allCases, [SupabaseManagementRelationship.launched, .adopted, .restored])
    func stoppedSupabaseLosesManagement(
        confirmation: StopConfirmation,
        relationship: SupabaseManagementRelationship
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let service = try #require(project.services.first)
        let world = FakeSupabaseWorld()
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)
        if relationship == .launched {
            _ = try await coordinator.start(project, registeredProjects: [project])
        } else {
            let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
            let configuration = try #require(service.supabaseConfiguration)
            await world.setStack("bell", .databaseHealthy)
            await registry.setKnownSupabaseConfigurations([projectID: configuration])
            _ = try await registry.adoptManagedStack(
                service: service, in: project, configuration: configuration,
                projectID: projectID, relationship: relationship,
                observation: SupabaseStackObservation(projectID: projectID, state: .running)
            )
        }

        switch confirmation {
        case .stop:
            _ = try await registry.stop(service: service)
        case .forceStop:
            _ = try await registry.forceStop(service: service)
        case .observation:
            await world.setStack("bell", nil)
            _ = await registry.observeSupabaseStacks()
        case .failedStop:
            await world.setStack("bell", nil)
            await world.failStop(.unavailable("CLI unavailable"))
            await #expect(throws: SupabaseOperationError.self) {
                _ = try await registry.stop(service: service)
            }
            await world.failStop(nil)
        }
        #expect(await registry.managedRelationship(serviceID: service.id) == nil)
        #expect(await registry.managedObservation(serviceID: service.id) == nil)
        #expect(await registry.managedSupabaseProjectIDs().isEmpty)
        #expect(try await registry.managedRuntimeHints().isEmpty)

        await world.setStack("bell", .databaseHealthy)
        await world.resetCommands()
        await coordinator.observeSupabaseStacks(registeredProjects: [project])
        #expect(await registry.isOccupyingResources(serviceID: service.id) == false)
        // 古い開発環境の停止を試しても、外部再起動したスタックは対象にならない。
        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
        #expect(await world.runningProjectIDs == ["bell"])
    }

    @Test("管理対象の設定を解決できずDockerも読めない場合に、停止導線とhintを失わない")
    func unresolvedManagedSupabaseRemainsUnknown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let service = try #require(project.services.first)
        let world = FakeSupabaseWorld()
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)
        _ = try await coordinator.start(project, registeredProjects: [project])
        let originalHints = try await registry.managedRuntimeHints()

        // ファイル自体を失う場合と同じく、現在の設定からIDを解決できなくする。
        try Data("[db]\n".utf8).write(to: directory.appendingPathComponent("supabase/config.toml"))
        await world.failInventory("Docker unavailable")
        let snapshot = await coordinator.observeSupabaseStacks(registeredProjects: [project])

        #expect(snapshot.hasUnknown)
        #expect(await registry.managedObservation(serviceID: service.id)?.state == .unknown)
        #expect(await registry.managedObservation(serviceID: service.id)?.detail == "Docker unavailable")
        #expect(await registry.isOccupyingResources(serviceID: service.id))
        #expect(await coordinator.servicePhase(service, in: project) == .residual)
        #expect(try await registry.managedRuntimeHints() == originalHints)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.stop(project, registeredProjects: [project])
        }
        #expect(await registry.isOccupyingResources(serviceID: service.id))
        #expect(try await registry.managedRuntimeHints() == originalHints)
    }

    @Test("保存失敗の補償は新しい通常プロセスだけを止め、引き継いだSupabaseを残す")
    func unsavedStartStopsWorkerButPreservesAdoptedSupabase() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = makeService(
            name: "Worker", ports: [], executable: "/bin/sleep",
            arguments: ["120"], workingDirectory: directory
        )
        let project = try makeSupabaseProject(directory: directory, extraServices: [worker])
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)
        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("引き継ぎ確認が必要")
            return
        } catch {
            plan = try confirmationPlan(error)
        }
        _ = try await coordinator.start(project, registeredProjects: [project], supabaseApproval: plan.approval)
        defer {
            Task { _ = try? await registry.stop(service: worker, grace: .seconds(1)) }
        }
        #expect(await registry.isRunning(serviceID: worker.id))

        try await coordinator.stopAfterUnsavedStart(project, preserving: [])

        #expect(await registry.isOccupyingResources(serviceID: worker.id) == false)
        #expect(await world.runningProjectIDs == ["bell"])
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(await coordinator.projectFact(project).phase == .residual)
        let hint = try #require(try await registry.managedRuntimeHints().first)
        #expect(hint.relationship == .adopted)
        _ = try await coordinator.stop(project, registeredProjects: [project])
    }

    @Test("同一IDのrunningは確認するまで何も実行せず、承認後はstartを実行しない")
    func adoptsRunningStackOnlyAfterApproval() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("確認なしで起動した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }

        #expect(plan.target.action == .adopt)
        #expect(plan.target.projectID.rawValue == "bell")
        #expect(plan.target.registration?.projectName == "Bell")
        #expect(plan.stopTargets.isEmpty)
        // 未承認の時点では start も stop も実行しない。
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(await world.commandLines.allSatisfy { !$0.contains(" start") })

        await world.resetCommands()
        _ = try await coordinator.start(
            project,
            registeredProjects: [project],
            supabaseApproval: plan.approval
        )

        let service = try #require(project.services.first)
        #expect(await registry.managedRelationship(serviceID: service.id) == .adopted)
        #expect(await coordinator.servicePhase(service, in: project) == .healthy)
        // 引き継ぎでは `supabase start` を実行しない。
        #expect(await world.commandLines.allSatisfy { !$0.contains(" start") })
        #expect(await world.runningProjectIDs == ["bell"])
    }

    @Test("引き継いだスタックは開発環境の停止で対象限定stopを実行する")
    func stopsAdoptedStackWithProject() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("確認なしで起動した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }
        _ = try await coordinator.start(
            project,
            registeredProjects: [project],
            supabaseApproval: plan.approval
        )

        await world.resetCommands()
        _ = try await coordinator.stop(project, registeredProjects: [project])

        #expect(await world.runningProjectIDs.isEmpty)
        #expect(await world.commandLines.contains { $0.contains("stop") && $0.contains("--project-id bell") })
        #expect(await coordinator.projectFact(project).phase == .stopped)
    }

    // MARK: - 復旧

    @Test("degradedは承認後だけ、対象限定stop・停止確認・start・running確認の順に進む")
    func recoversDegradedStackInOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let world = FakeSupabaseWorld(stacks: ["bell": .degraded(reason: "DBコンテナがありません")])
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("承認前に復旧した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }
        #expect(plan.target.action == .restart)
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })

        await world.resetCommands()
        _ = try await coordinator.start(
            project,
            registeredProjects: [project],
            supabaseApproval: plan.approval
        )

        let commands = await world.commandLines
        let stopIndex = try #require(commands.firstIndex { $0.contains("stop") })
        let startIndex = try #require(commands.firstIndex { $0.contains(" start") })
        // 停止 → 起動 の順。停止を確認する前に起動しない。
        #expect(stopIndex < startIndex)
        // 起動後は running を status まで確認する。
        #expect(commands[(startIndex + 1)...].contains { $0.contains("status") })
        #expect(await world.runningProjectIDs == ["bell"])
    }

    // MARK: - 別スタックの停止

    @Test("別IDが複数あっても1つの確認にまとめ、承認後は1件ずつ停止する")
    func stopsEveryForeignStackIndividually() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bellDirectory = root.appendingPathComponent("bell", isDirectory: true)
        let pentaDirectory = root.appendingPathComponent("penta", isDirectory: true)
        for directory in [bellDirectory, pentaDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let project = try makeSupabaseProject(directory: bellDirectory)
        let registered = try makeSupabaseProject(
            name: "Penta",
            projectID: "penta",
            directory: pentaDirectory
        )
        let world = FakeSupabaseWorld(stacks: [
            "penta": .databaseHealthy,
            "legacy": .degraded(reason: "DBコンテナが exited 状態です。"),
        ])
        let (_, coordinator) = makeStack(world: world, logDirectory: root)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project, registered])
            Issue.record("確認なしで既存スタックを停止した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }

        #expect(plan.target.action == .start)
        #expect(plan.stopTargets.map(\.projectID.rawValue) == ["legacy", "penta"])
        // 登録済みと未登録を区別して表示する。
        #expect(plan.stopTargets.first { $0.projectID.rawValue == "penta" }?
            .registration?.projectName == "Penta")
        #expect(plan.stopTargets.first { $0.projectID.rawValue == "legacy" }?
            .registration == nil)
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })

        await world.resetCommands()
        _ = try await coordinator.start(
            project,
            registeredProjects: [project, registered],
            supabaseApproval: plan.approval
        )

        let stops = await world.commandLines.filter { $0.contains("stop") }
        #expect(stops.count == 2)
        #expect(stops.contains { $0.contains("--project-id legacy") })
        #expect(stops.contains { $0.contains("--project-id penta") })
        // `--all`と`--no-backup`はどの経路でも実行しない。
        #expect(await world.commandLines.allSatisfy {
            !$0.contains("--all") && !$0.contains("--no-backup")
        })
        #expect(await world.runningProjectIDs == ["bell"])
    }

    @Test("承認後に状態が変わっていたら、停止も起動もせず最新内容で確認し直す")
    func revalidatesApprovalBeforeChangingAnything() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let world = FakeSupabaseWorld(stacks: ["other": .databaseHealthy])
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("確認なしで起動した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }

        // 承認の直後に、確認時と違うスタックが増えた。
        await world.setStack("late", .databaseHealthy)
        await world.resetCommands()

        do {
            _ = try await coordinator.start(
                project,
                registeredProjects: [project],
                supabaseApproval: plan.approval
            )
            Issue.record("変わった状態のまま実行した")
            return
        } catch {
            let latest = try confirmationPlan(error)
            #expect(latest.stopTargets.map(\.projectID.rawValue) == ["late", "other"])
        }
        // 再確認までは何も停止・起動しない。
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(await world.runningProjectIDs == ["late", "other"])
    }

    // MARK: - failurePolicy との境界

    @Test("unknownでは確認へ進まず、failurePolicy: continue でも後続を起動しない")
    func unknownStateBlocksEverythingRegardlessOfFailurePolicy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")
        var supabase = makeSupabaseService(workingDirectory: directory)
        supabase.failurePolicy = .continue
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let follower = makeOrderedService(
            name: "Web",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [supabase, follower])
        let world = FakeSupabaseWorld()
        await world.failInventory("docker daemon が応答しません。")
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("観測できないまま起動した")
        } catch {
            let failure = try #require(error as? SwitchFailure)
            guard case let .supabaseObservationFailed(details) = failure.reason else {
                Issue.record("観測失敗ではない: \(failure.reason)")
                return
            }
            #expect(details.contains { $0.contains("docker daemon") })
        }

        #expect(readLines(startLog).isEmpty)
        #expect(await world.commandLines.allSatisfy { !$0.contains(" start") })
    }

    @Test("既存スタックの停止に失敗したら後続を中断し、停止済みを再起動しない")
    func abortsWhenForeignStackStopFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let world = FakeSupabaseWorld(stacks: ["other": .databaseHealthy])
        await world.failStop(.exit(code: 7))
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("確認なしで起動した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }

        do {
            _ = try await coordinator.start(
                project,
                registeredProjects: [project],
                supabaseApproval: plan.approval
            )
            Issue.record("停止に失敗したのに起動した")
        } catch {
            let failure = try #require(error as? SwitchFailure)
            guard case let .supabaseStopFailed(projectID, _, stopped, _) = failure.reason else {
                Issue.record("停止失敗ではない: \(failure.reason)")
                return
            }
            #expect(projectID == "other")
            #expect(stopped.isEmpty)
        }
        // 対象は起動しない。停止できなかったスタックも残したまま。
        #expect(await world.commandLines.allSatisfy { !$0.contains(" start") })
        #expect(await world.runningProjectIDs == ["other"])
    }

    @Test("start失敗後に非稼働を確認できた場合だけfailurePolicyを適用する")
    func appliesFailurePolicyOnlyAfterConfirmingNotRunning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")
        try writeSupabaseConfig(projectID: "bell", in: directory)
        var supabase = makeSupabaseService(workingDirectory: directory)
        supabase.failurePolicy = .continue
        let follower = makeOrderedService(
            name: "Web",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [supabase, follower])
        let world = FakeSupabaseWorld()
        await world.failStart(.exit(code: 9))
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        let outcome = try await coordinator.start(project, registeredProjects: [project])

        // スタックが無いため自動停止は不要で、continueを適用する。
        #expect(outcome.degradedServices == ["Supabase"])
        #expect(readLines(startLog) == ["Web"])
        #expect(await coordinator.servicePhase(supabase, in: project) != .residual)
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })

        _ = try await coordinator.stop(project, registeredProjects: [project])
    }

    @Test("running確認不能な起動試行は停止権限を持たず、自動停止しない")
    func unconfirmedStartDoesNotAcquireStopAuthority() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")
        try writeSupabaseConfig(projectID: "bell", in: directory)
        var supabase = makeSupabaseService(workingDirectory: directory)
        supabase.failurePolicy = .continue
        let follower = makeOrderedService(
            name: "Web",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [supabase, follower])
        // startは成功するがrunning確認が通らない。由来を確定できない状態を再現する。
        let world = FakeSupabaseWorld()
        await world.failStatus(.exit(code: 1))
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project])
        }

        #expect(await registry.managedRelationship(serviceID: supabase.id) == nil)
        #expect(await world.runningProjectIDs == ["bell"])
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(readLines(startLog).isEmpty)
    }

    @Test("start実行中に現れた外部Supabaseを自動停止しない")
    func externalStackRaceDoesNotAcquireStopAuthority() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")
        try writeSupabaseConfig(projectID: "bell", in: directory)
        var supabase = makeSupabaseService(workingDirectory: directory)
        supabase.failurePolicy = .continue
        let follower = makeOrderedService(
            name: "Web",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [supabase, follower])
        let world = FakeSupabaseWorld()
        await world.makeStackAppearWhenStartRuns("bell", observation: .databaseHealthy)
        await world.failStart(.exit(code: 9))
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project])
        }

        if let failure {
            guard case let .startFailed(_, reason) = failure.reason else {
                Issue.record("起動失敗ではない: \(failure.reason)")
                return
            }
            #expect(reason.contains("自動停止していません"))
        }
        #expect(await registry.managedRelationship(serviceID: supabase.id) == nil)
        #expect(await world.runningProjectIDs == ["bell"])
        #expect(await world.commandLines.contains { $0.contains(" start") })
        #expect(await world.commandLines.allSatisfy { !$0.contains("stop") })
        #expect(readLines(startLog).isEmpty)
    }

    @Test("管理中Supabaseのdegradedは停止中ではなく残存ありにする")
    func managedDegradedStackRemainsStoppable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let supabase = try #require(project.services.first)
        let world = FakeSupabaseWorld()
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)
        _ = try await coordinator.start(project, registeredProjects: [project])

        await world.setStack("bell", .degraded(reason: "DBコンテナがありません"))
        _ = await coordinator.observeSupabaseStacks(registeredProjects: [project])

        #expect(await coordinator.servicePhase(supabase, in: project) == .residual)
        #expect(await coordinator.projectFact(project).phase == .residual)

        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(await world.runningProjectIDs.isEmpty)
    }

    @Test("管理中Supabaseのunknownは停止中ではなく残存ありにする")
    func managedUnknownStackRemainsStoppable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeSupabaseProject(directory: directory)
        let supabase = try #require(project.services.first)
        let world = FakeSupabaseWorld()
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)
        _ = try await coordinator.start(project, registeredProjects: [project])

        await world.failStatus(.exit(code: 1))
        _ = await coordinator.observeSupabaseStacks(registeredProjects: [project])

        #expect(await coordinator.servicePhase(supabase, in: project) == .residual)
        #expect(await coordinator.projectFact(project).phase == .residual)

        await world.failStatus(nil)
        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(await world.runningProjectIDs.isEmpty)
    }

    @Test("引き継ぎ後に停止を観測したら、次にアプリが起動したSupabaseは巻き戻し対象になる")
    func observedStopClearsPreviousAdoptionForRollback() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = makeFailingService(name: "Web", workingDirectory: directory, failurePolicy: .block)
        let project = try makeSupabaseProject(directory: directory, extraServices: [failing])
        let supabase = try #require(project.services.first)
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)
        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("引き継ぎ確認が必要")
            return
        } catch {
            plan = try confirmationPlan(error)
        }
        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project], supabaseApproval: plan.approval)
        }
        #expect(await registry.managedRelationship(serviceID: supabase.id) == .adopted)

        await world.setStack("bell", nil)
        await coordinator.observeSupabaseStacks(registeredProjects: [project])
        #expect(await coordinator.servicePhase(supabase, in: project) == .stopped)
        await world.resetCommands()
        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project])
        }
        #expect(await world.commandLines.contains { $0.contains(" start") })
        #expect(await world.commandLines.contains { $0.contains("stop") })
        #expect(await world.runningProjectIDs.isEmpty)
        #expect(await registry.managedRelationship(serviceID: supabase.id) == nil)
    }

    @Test("後続のblock失敗では今回起動したSupabaseを停止する")
    func rollsBackLaunchedSupabaseOnBlockingFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let supabase = makeSupabaseService(workingDirectory: directory)
        let failing = makeFailingService(
            name: "Web",
            workingDirectory: directory,
            failurePolicy: .block
        )
        let project = makeProject(directory: directory, services: [supabase, failing])
        let world = FakeSupabaseWorld()
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project])
        }

        // 今回起動した分は巻き戻す。
        #expect(await world.runningProjectIDs.isEmpty)
        #expect(await registry.isRunning(serviceID: supabase.id) == false)
        #expect(await world.commandLines.contains { $0.contains("--project-id bell") })
    }

    @Test("引き継いだSupabaseは後続のblock失敗でも停止せず、残存ありとして残る")
    func keepsAdoptedSupabaseOnBlockingFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let supabase = makeSupabaseService(workingDirectory: directory)
        let failing = makeFailingService(
            name: "Web",
            workingDirectory: directory,
            failurePolicy: .block
        )
        let project = makeProject(directory: directory, services: [supabase, failing])
        let world = FakeSupabaseWorld(stacks: ["bell": .databaseHealthy])
        let (registry, coordinator) = makeStack(world: world, logDirectory: directory)

        let plan: SupabaseConfirmationPlan
        do {
            _ = try await coordinator.start(project, registeredProjects: [project])
            Issue.record("確認なしで起動した")
            return
        } catch {
            plan = try confirmationPlan(error)
        }

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(
                project,
                registeredProjects: [project],
                supabaseApproval: plan.approval
            )
        }

        // 引き継いだスタックは巻き戻さない。停止導線は残す。
        #expect(await world.runningProjectIDs == ["bell"])
        #expect(await registry.managedRelationship(serviceID: supabase.id) == .adopted)
        #expect(await coordinator.servicePhase(supabase, in: project) == .residual)
        #expect(await coordinator.projectFact(project).phase == .residual)

        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(await world.runningProjectIDs.isEmpty)
    }

    // MARK: - 切替

    @Test("切替元の管理下Supabaseには停止確認を重ねて出さない")
    func doesNotReconfirmManagedStackOfSwitchSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("bell", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("penta", isDirectory: true)
        for directory in [sourceDirectory, targetDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let source = try makeSupabaseProject(directory: sourceDirectory)
        let target = try makeSupabaseProject(
            name: "Penta",
            projectID: "penta",
            directory: targetDirectory
        )
        let world = FakeSupabaseWorld()
        let (_, coordinator) = makeStack(world: world, logDirectory: root)

        // 切替元を先に起動しておく（今回起動＝launched）。
        _ = try await coordinator.start(source, registeredProjects: [source, target])
        #expect(await world.runningProjectIDs == ["bell"])

        await world.resetCommands()
        // 切替元の bell は通常の停止処理で止まるので、Supabase固有の確認は出さない。
        _ = try await coordinator.switchProject(
            from: source,
            to: target,
            registeredProjects: [source, target]
        )

        #expect(await world.runningProjectIDs == ["penta"])
        let stops = await world.commandLines.filter { $0.contains("stop") }
        #expect(stops.count == 1)
        #expect(stops.allSatisfy { $0.contains("--project-id bell") })
    }

    @Test("起動直前に project_id が重複していれば起動せず、停止導線は残す")
    func refusesToStartWhenProjectIDsCollideAtRuntime() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bellDirectory = root.appendingPathComponent("bell", isDirectory: true)
        let otherDirectory = root.appendingPathComponent("other", isDirectory: true)
        for directory in [bellDirectory, otherDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let project = try makeSupabaseProject(directory: bellDirectory)
        // 保存後に別の開発環境が同じ`project_id`を指すようになった状態。
        let colliding = try makeSupabaseProject(
            name: "Penta",
            projectID: "bell",
            directory: otherDirectory
        )
        let world = FakeSupabaseWorld()
        let (_, coordinator) = makeStack(world: world, logDirectory: root)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(
                project,
                registeredProjects: [project, colliding]
            )
        }
        #expect(await world.commandLines.isEmpty)

        // 停止は復旧手段なので、この理由では止めない。
        _ = try await coordinator.stop(project, registeredProjects: [project, colliding])
    }

    @Test("実行境界でも --all と --no-backup を拒否する")
    func processRunnerRejectsForbiddenOptions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = SupabaseProcessCommandRunner(environmentProvider: { fixedShellEnvironment })

        for option in ["--all", "--no-backup"] {
            await #expect(throws: SupabaseCommandError.self) {
                _ = try await runner.run(
                    CommandSpec(
                        executable: "supabase",
                        arguments: ["stop", option],
                        workingDirectory: directory
                    )
                )
            }
        }
    }

    @Test("project_idを解決できない設定では起動しない")
    func refusesToStartWhenProjectIDCannotBeResolved() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // config.toml を用意しない。
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )
        let world = FakeSupabaseWorld()
        let (_, coordinator) = makeStack(world: world, logDirectory: directory)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project, registeredProjects: [project])
        }
        #expect(await world.commandLines.isEmpty)
    }
}
