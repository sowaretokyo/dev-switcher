import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("対象外プロセスの追加起動")
struct ServiceStartTests {
    private func makeRegistry(directory: URL, world: ControlledProcessWorld) -> RuntimeRegistry {
        RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            identityProbe: { world.identity(pid: $0, workingDirectory: $1) },
            portProbe: { _ in [] },
            signalSender: { world.send(processGroupID: $0, signal: $1) },
            groupStateProbe: { world.groupState(processGroupID: $0) },
            startAbstimeProbe: { world.startObservation(pid: $0) },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )
    }

    private func withStack(
        _ body: (ProjectDefinition, RuntimeRegistry, SwitchCoordinator, ControlledProcessWorld) async throws -> Void
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let world = ControlledProcessWorld()
        let registry = makeRegistry(directory: directory, world: world)
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20)
            )
        )
        let web = makeService(
            name: "Web", ports: [], executable: "/bin/sleep", arguments: ["120"],
            workingDirectory: directory
        )
        let inngest = makeService(
            name: "Inngest", kind: .inngest, ports: [], executable: "/bin/sleep", arguments: ["120"],
            workingDirectory: directory, enabledByDefault: false, failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [web, inngest])
        do {
            try await body(project, registry, coordinator, world)
        } catch {
            _ = try? await coordinator.stop(project)
            throw error
        }
        _ = try await coordinator.stop(project)
    }

    @Test("追加した1件も再起動・全体停止でき、次回の一括起動では対象外に戻る")
    func startsOnlyForThisRun() async throws {
        try await withStack { project, registry, coordinator, world in
            let web = project.services[0]
            let inngest = project.services[1]
            _ = try await coordinator.start(project)
            let webPID = try #require(await registry.runtimeSnapshot(serviceID: web.id)?.processID)
            #expect(await coordinator.servicePhase(inngest, in: project) == .excluded)
            world.clearSignals()

            let fact = try await coordinator.startService(inngest, in: project)
            let inngestPID = try #require(await registry.runtimeSnapshot(serviceID: inngest.id)?.processID)
            #expect(fact.phase == .running)
            #expect(await coordinator.servicePhase(inngest, in: project) == .healthy)
            #expect(await registry.runtimeSnapshot(serviceID: web.id)?.processID == webPID)
            #expect(world.signals.isEmpty)
            #expect(!project.isEnabledNow(inngest.id))
            #expect(Set(try await registry.runtimeHints().map(\.serviceID)) == Set([web.id, inngest.id]))

            _ = try await coordinator.restart(inngest, in: project)
            let restartedPID = try #require(await registry.runtimeSnapshot(serviceID: inngest.id)?.processID)
            #expect(restartedPID != inngestPID)
            #expect(await registry.runtimeSnapshot(serviceID: web.id)?.processID == webPID)
            world.clearSignals()

            _ = try await coordinator.stop(project)
            #expect(world.signals.map(\.processGroupID) == [restartedPID, webPID])
            #expect(await coordinator.servicePhase(inngest, in: project) == .excluded)
            #expect(try await registry.runtimeHints().isEmpty)

            _ = try await coordinator.start(project)
            #expect(await registry.isRunning(serviceID: web.id))
            #expect(await registry.isRunning(serviceID: inngest.id) == false)
            #expect(await coordinator.servicePhase(inngest, in: project) == .excluded)
        }
    }

    @Test("追加起動失敗は環境の状態へ反映し、既存プロセスを停止しない",
          arguments: [FailurePolicy.block, .continue], [false, true])
    func failureKeepsSiblingsRunning(policy: FailurePolicy, exitsImmediately: Bool) async throws {
        try await withStack { original, registry, coordinator, world in
            var project = original
            project.services[1].failurePolicy = policy
            project.services[1].start.executable = exitsImmediately ? "/bin/sh" : "/nonexistent/dev-switcher-test"
            project.services[1].start.arguments = exitsImmediately ? ["-c", "echo start-failed >&2; exit 7"] : []
            let web = project.services[0]
            let inngest = project.services[1]
            _ = try await coordinator.start(project)
            let webPID = try #require(await registry.runtimeSnapshot(serviceID: web.id)?.processID)
            world.clearSignals()

            let failure = try #require(await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(inngest, in: project)
            })
            #expect(await registry.runtimeSnapshot(serviceID: web.id)?.processID == webPID)
            #expect(await registry.isRunning(serviceID: web.id))
            #expect(!world.signals.contains { $0.processGroupID == webPID })
            #expect(await registry.isOccupyingResources(serviceID: inngest.id) == false)
            if policy == .continue {
                #expect(failure.facts.target?.phase == .degraded(stoppedServices: [inngest.name]))
            } else {
                guard case .failed = failure.facts.target?.phase else {
                    Issue.record("追加起動の失敗が開発環境に反映されていません。")
                    return
                }
            }
        }
    }

    @Test("追加起動したプロセスは、引き継ぎ後に終了しても失敗表示から消えない",
          arguments: [FailurePolicy.block, .continue])
    func reportsExitAfterHandoff(policy: FailurePolicy) async throws {
        try await withStack { original, registry, coordinator, world in
            var project = original
            project.services[1].failurePolicy = policy
            let web = project.services[0]
            let inngest = project.services[1]
            let directory = web.start.workingDirectory
            _ = try await coordinator.start(project)
            _ = try await coordinator.startService(inngest, in: project)
            let webPID = try #require(await registry.runtimeSnapshot(serviceID: web.id)?.processID)
            let inngestPID = try #require(await registry.runtimeSnapshot(serviceID: inngest.id)?.processID)

            // 新しいRegistryとCoordinatorには、起動元の終了イベントが届かない。
            // 手掛かりを観測値と照合し、アプリ再起動後と同じ入口から引き継ぐ。
            let inspector = HandoffInspector(
                startAbstimeProbe: { world.startObservation(pid: $0) },
                startTimeProbe: { _ in 1_000_000 },
                executablePathProbe: { _ in "/bin/sleep" },
                workingDirectoryProbe: { _ in directory },
                portProbe: { _ in [] },
                groupStateProbe: { world.groupState(processGroupID: $0) },
                bootSessionProbe: { "TEST-BOOT-SESSION" }
            )
            let hints = try await registry.runtimeHints()
            let review = await inspector.review(RuntimeHintsLoad(hints: hints))
            try #require(review.candidates.count == 2)
            let restoredRegistry = makeRegistry(directory: directory, world: world)
            let restored = SwitchCoordinator(
                registry: restoredRegistry,
                portHolderProbe: { _ in [] },
                options: SwitchCoordinator.Options(
                    stopGrace: .seconds(2),
                    startupObservationWindow: .milliseconds(100),
                    startupPollInterval: .milliseconds(20)
                )
            )
            for service in project.services {
                let candidate = try #require(review.candidates.first { $0.hint.serviceID == service.id })
                try await restored.adopt(candidate, service: service, in: project)
            }
            #expect(await restored.servicePhase(inngest, in: project) == .healthy)
            #expect(await restored.projectFact(project).phase == .running)

            // Dev Switcherの停止操作を通さずに終了させ、同じタイミングで観測値も切り替える。
            #expect(world.send(processGroupID: inngestPID, signal: SIGTERM) == 0)
            world.clearSignals()
            let phase = await restored.servicePhase(inngest, in: project)
            guard case .failed = phase else {
                Issue.record("引き継ぎ後の終了が失敗表示から消えています: \(phase)")
                return
            }
            let fact = await restored.projectFact(project)
            if policy == .continue {
                #expect(fact.phase == .degraded(stoppedServices: [inngest.name]))
            } else {
                guard case .failed = fact.phase else {
                    Issue.record("必須プロセスの終了が環境全体の失敗へ反映されていません。")
                    return
                }
            }
            #expect(await restored.servicePhase(inngest, in: project) == phase)
            #expect(await restoredRegistry.runtimeSnapshot(serviceID: web.id)?.processID == webPID)
            #expect(await restoredRegistry.isRunning(serviceID: web.id))
            #expect(world.signals.isEmpty)
            #expect(!project.isEnabledNow(inngest.id))

            _ = try await restored.stop(project)
            #expect(await restored.servicePhase(inngest, in: project) == .excluded)
            #expect(await restored.projectFact(project).phase == .stopped)
            // このテストでは起動元も同じテストプロセス内に残る。
            // 起動元が実際の終了を受信してから、withStackの後片付けへ戻す。
            let projectID = project.id
            let drained = await waitUntil {
                await registry.occupyingServiceIDs(projectID: projectID).isEmpty
            }
            #expect(drained)
        }
    }

    @Test("停止中の環境・他環境・二重起動・Supabase・未登録設定をCore APIでも拒否する")
    func rejectsInvalidStarts() async throws {
        try await withStack { project, registry, coordinator, world in
            let web = project.services[0]
            let inngest = project.services[1]
            await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(inngest, in: project)
            }
            #expect(await registry.occupyingServiceIDs(projectID: project.id).isEmpty)
            _ = try await coordinator.start(project)
            let webPID = try #require(await registry.runtimeSnapshot(serviceID: web.id)?.processID)
            world.clearSignals()

            await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(web, in: project)
            }
            var other = project
            other.id = UUID()
            await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(inngest, in: other)
            }
            var altered = inngest
            altered.start.arguments = ["99"]
            await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(altered, in: project)
            }
            var withSupabase = project
            withSupabase.services[1].kind = .supabase
            await #expect(throws: SwitchFailure.self) {
                try await coordinator.startService(withSupabase.services[1], in: withSupabase)
            }
            #expect(await registry.runtimeSnapshot(serviceID: web.id)?.processID == webPID)
            #expect(await registry.isRunning(serviceID: inngest.id) == false)
            #expect(world.signals.isEmpty)
        }
    }
}
