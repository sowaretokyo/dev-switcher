@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("Mac再起動とDocker復旧")
@MainActor
struct AppStateRelaunchTests {
    @Test("Mac再起動後は同じPIDが存在しても古い通常プロセスを引き継がない")
    func rebootDiscardsPreviousBootHints() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        let hints = RuntimeHintStore(directory: directory)
        try hints.save([fixture.hint])
        // PID・開始abstimeが偶然一致していても、Macの起動セッションが違えば別物。
        fixture.observations.setBootSessionID("AFTER-MAC-REBOOT")
        let state = makeAppState(
            directory: directory, registry: fixture.registry, handoffInspector: fixture.inspector
        )

        await state.bootstrap()

        #expect(state.handoffPresentation == nil)
        #expect(state.activeProject == nil)
        #expect(state.phase(of: fixture.project) == .stopped)
        #expect(state.canStart)
        #expect(try hints.load().isEmpty)
        #expect(fixture.signals.sent.isEmpty)
    }

    @Test("再起動直後にDockerが未起動でも、再観測で復旧して操作を再開できる",
          arguments: [ManagedStackState.notRunning, .running, .degraded])
    func dockerRecoveryAfterReboot(recoveredState: ManagedStackState) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "relaunch", in: directory)
        let stackID = try #require(SupabaseProjectID(rawValue: "relaunch"))
        let supabase = makeAppStateSupabaseService(workingDirectory: directory)
        let worker = try #require(makeWorkerProject(directory: directory).services.first)
        let project = ProjectDefinition(
            name: "Bell", color: .blue, directory: directory, services: [supabase, LaunchUnit(worker)]
        )
        try ProjectStore(directory: directory).save([project])
        let hints = RuntimeHintStore(directory: directory)
        let managed = try #require(makeManagedStackHint(
            projectID: project.id, service: supabase,
            supabaseProjectID: stackID, relationship: .launched
        ))
        try hints.save([
            makeStoredHint(projectID: project.id, serviceID: worker.id, directory: directory),
        ], legacy: [], managed: [managed])
        let world = FakeSupabaseWorld()
        await world.failInventory("Cannot connect to the Docker daemon. Is the docker daemon running?")
        let inspector = HandoffInspector(bootSessionProbe: { "AFTER-MAC-REBOOT" })
        let state = makeAppState(
            directory: directory, handoffInspector: inspector, supabaseWorld: world
        )

        await state.bootstrap()

        #expect(state.handoffPresentation == nil)
        #expect(state.managedHintError != nil)
        #expect(state.managedStackObservationError != nil)
        #expect(!state.canStart)
        #expect(try hints.load().hints.isEmpty)
        #expect(try hints.load().managed == [managed])
        #expect(await world.commandLines.isEmpty)

        await world.failInventory(nil)
        switch recoveredState {
        case .running: await world.setStack("relaunch", .databaseHealthy)
        case .degraded: await world.setStack("relaunch", .degraded(reason: "DB stopped"))
        case .notRunning: break
        case .unknown: Issue.record("復旧後の状態を指定してください。")
        }
        // 画面の「再観測」とフォアグラウンド復帰が使う入口。
        await state.applicationDidBecomeActive()

        #expect(state.managedHintError == nil)
        #expect(state.managedStackObservationError == nil)
        #expect(state.handoffPresentation == nil)
        #expect(state.managedStackConfirmation == nil)
        #expect(state.canStart)
        #expect(state.state(of: supabase.id).managedStack?.state == recoveredState)
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
        if recoveredState == .notRunning {
            #expect(try hints.load().isEmpty)
            #expect(state.activeProject == nil)
        } else {
            #expect(state.state(of: supabase.id).managedStack?.relationship == .restored)
            #expect(state.hasManagedResources(in: project))
            #expect(state.canStop)
            #expect(try hints.load().managed.count == 1)
        }
    }
}
