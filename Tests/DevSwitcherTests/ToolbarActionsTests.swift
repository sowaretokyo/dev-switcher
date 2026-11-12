@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("ツールバーの操作")
@MainActor
struct ToolbarActionsTests {
    @Test("管理資源がなくなっても、停止処理が完了するまでヘッダーの対象を保つ")
    func stoppingProjectRemainsVisibleAfterResourcesDisappear() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = ArmedGate()
        let fixture = makeSyntheticFixture(directory: directory, portProbe: { _ in
            await gate.passOrWait()
            return []
        })
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])
        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        await state.bootstrap()
        let handoff = try #require(state.handoffPresentation)
        state.performHandoffAction(.adopt, presentationID: handoff.id)
        await state.waitForPendingOperation()
        #expect(state.activeProject?.id == fixture.project.id)

        await gate.arm()
        state.stopProject(fixture.project)
        #expect(await gate.waitUntilReached())

        // 停止処理を待機させたまま実測上の資源をなくし、進捗イベントで再観測する。
        fixture.observations.setGroupState(.members([]), for: fixture.hint.processGroupID)
        fixture.observations.setStartObservation(.notPresent, for: fixture.hint.leader.pid)
        let progress = try #require(state.progressSinkForCurrentActivity())
        progress(.stopping(service: fixture.service.name, index: 1, total: 1))
        #expect(await waitForCondition { state.activeProject == nil })
        #expect(state.toolbarProject?.id == fixture.project.id)
        #expect(state.phase(of: fixture.project) == .stopping)
        #expect(!state.canStop)

        await gate.release()
        await state.waitForPendingOperation()
        #expect(state.operationError == nil)
        #expect(state.toolbarProject == nil)
    }

    @Test("資源がまだない起動直後も対象を表示し、起動失敗後は空状態へ戻る")
    func startingProjectRemainsVisibleWithoutManagedResources() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        let selected = makeWorkerProject(name: "Penta", directory: directory)
        try ProjectStore(directory: directory).save([project, selected])
        let hints = ControllableHintStore(directory: directory)
        let state = makeAppState(directory: directory, hintStore: hints)
        await state.bootstrap()

        state.selection = .project(selected.id)
        #expect(state.toolbarProject == nil)

        // 事前保存で失敗させ、実プロセスを起動せずに進捗表示を検証する。
        hints.failAllSaves()
        state.startOrSwitch(to: project)
        state.selection = .project(selected.id)

        #expect(state.activeProject == nil)
        #expect(state.toolbarProject?.id == project.id)
        #expect(state.phase(of: project) == .starting)
        #expect(!state.canStop)
        #expect(state.primaryControl(for: project) == .inProgress(
            AppState.InlineOperation(projectID: project.id, kind: .starting)
        ))

        await state.waitForPendingOperation()

        #expect(state.operationError != nil)
        #expect(state.inlineOperation == nil)
        #expect(state.toolbarProject == nil)
    }

    @Test("URL付きポートがない場合は開くメニューを表示しない")
    func openMenuVisibilityDependsOnOpenURL() {
        let directory = URL(fileURLWithPath: "/tmp/project-detail-test")
        let withoutPort = makeWorkerProject(directory: directory)
        let withoutURL = makeWorkerProject(
            directory: directory,
            ports: [PortSpec(port: 3000, isPrimary: true)]
        )
        let withURL = makeWorkerProject(
            directory: directory,
            ports: [
                PortSpec(
                    port: 3000,
                    isPrimary: true,
                    openURL: "http://localhost:3000"
                ),
            ]
        )

        #expect(!withoutPort.hasOpenableURLs)
        #expect(!withoutURL.hasOpenableURLs)
        #expect(withURL.hasOpenableURLs)
    }

    @Test("スタック側だけに URL がある環境でも開くメニューを表示する")
    func openMenuIncludesManagedStackURLs() {
        let directory = URL(fileURLWithPath: "/tmp/toolbar-stack-test")
        let configurations: [ManagedStackConfiguration] = [
            .supabase(.init(start: CommandSpec(executable: "supabase", arguments: ["start"], workingDirectory: directory))),
            .dockerCompose(.init(projectName: "shop")),
        ]
        let cases: [([PortSpec], Bool)] = [
            ([], false),
            ([PortSpec(port: 54323, isPrimary: true)], false),
            ([PortSpec(port: 54323, isPrimary: true, openURL: "http://localhost:54323")], true),
        ]
        for configuration in configurations {
            for (ports, hasURL) in cases {
                let stack = ManagedStackDefinition(id: UUID(), name: "DB", configuration: configuration,
                    ports: ports, enabledByDefault: true, failurePolicy: .block)
                let stackOnly = ProjectDefinition(name: "Stack", color: .blue,
                    workingDirectories: [.init(name: "Backend", directory: directory, serviceIDs: [], stackIDs: [stack.id])],
                    services: [DevSwitcherCore.ServiceDefinition](), managedStacks: [stack])
                var mixed = makeWorkerProject(directory: directory)
                mixed.managedStacks = [stack]
                mixed.workingDirectories[0].stackIDs = [stack.id]

                #expect(stackOnly.hasOpenableURLs == hasURL)
                #expect(mixed.hasOpenableURLs == hasURL)
            }
        }
    }
}
