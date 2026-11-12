import Foundation
import Testing
@testable import DevSwitcherApp
@testable import DevSwitcherCore

@Suite("追加起動の操作と保存")
@MainActor
struct AppStateServiceStartTests {
    /// 実際の子プロセスと保存ファイルを使い、利用者の環境には書き込まない。
    private func withProject(
        _ body: (AppState, ProjectDefinition, ControllableHintStore, URL) async throws -> Void
    ) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = makeWorkerProject(directory: directory, serviceNames: ["Web", "Inngest"])
        project.services[1].tag = "inngest"
        project.services[1].enabledByDefault = false
        project.services[1].failurePolicy = .continue
        try ProjectStore(directory: directory).save([project])
        let hints = ControllableHintStore(directory: directory)
        let state = makeAppState(directory: directory, hintStore: hints)
        await state.bootstrap()
        do {
            try await body(state, project, hints, directory)
        } catch {
            hints.allowSaves()
            state.stopProject(project)
            await state.waitForPendingOperation()
            throw error
        }
        hints.allowSaves()
        state.stopProject(project)
        await state.waitForPendingOperation()
    }

    private func startEnvironment(_ state: AppState, _ project: ProjectDefinition) async throws {
        state.startOrSwitch(to: project)
        await state.waitForPendingOperation()
        try #require(state.operationError == nil)
        try #require(state.phase(of: project) == .running)
    }

    @Test("追加起動の進捗・ログ・手掛かりを反映し、設定は変更しない")
    func startsWithoutChangingSelection() async throws {
        try await withProject { state, project, hints, directory in
            let web = project.services[0]
            let inngest = project.services[1]
            try await startEnvironment(state, project)
            let webPID = try #require(state.state(of: web.id).processID)
            let oldLog = LogLine(id: 0, timestamp: Date(), stream: .stderr, text: "previous session")
            state.logBuffer(of: web.id).append([oldLog])
            state.logBuffer(of: inngest.id).append([oldLog])
            #expect(state.canStartService(inngest, in: project))

            state.startService(inngest, in: project)
            #expect(state.serviceOperation?.serviceID == inngest.id)
            #expect(state.serviceOperation?.kind == .starting)
            #expect(state.serviceOperation?.label == "起動中")
            #expect(state.switchPresentation == nil)
            #expect(state.inlineOperation == nil)
            #expect(!state.canStartService(inngest, in: project))
            #expect(!state.canRestart(web, in: project))
            #expect(!state.canStop)
            await state.waitForPendingOperation()

            #expect(state.operationError == nil)
            #expect(state.serviceOperation == nil)
            #expect(state.state(of: inngest.id).phase == .healthy)
            #expect(state.state(of: web.id).processID == webPID)
            #expect(state.logBuffer(of: inngest.id).lines.isEmpty)
            #expect(state.logBuffer(of: inngest.id).stderrCount == 0)
            #expect(state.logBuffer(of: web.id).lines == [oldLog])
            #expect(state.canRestart(inngest, in: project))
            #expect(state.projects == [project])
            #expect(try ProjectStore(directory: directory).load() == [project])
            #expect(Set(try hints.load().hints.map(\.serviceID)) == Set([web.id, inngest.id]))

            state.stopProject(project)
            await state.waitForPendingOperation()
            #expect(state.state(of: inngest.id).phase == .excluded)
            #expect(try hints.load().hints.isEmpty)
            try await startEnvironment(state, project)
            #expect(state.state(of: inngest.id).phase == .excluded)
            #expect(state.state(of: inngest.id).processID == nil)
        }
    }

    @Test("事前の保存失敗では追加起動せず、他のプロセスと手掛かりを保持する")
    func failedPreSaveDoesNotStart() async throws {
        try await withProject { state, project, hints, _ in
            try await startEnvironment(state, project)
            let webPID = try #require(state.state(of: project.services[0].id).processID)
            let before = try hints.load()
            hints.failAllSaves()
            state.startService(project.services[1], in: project)
            await state.waitForPendingOperation()
            #expect(state.operationError?.contains("起動を中止") == true)
            #expect(state.serviceOperation == nil)
            #expect(state.state(of: project.services[1].id).phase == .excluded)
            #expect(state.state(of: project.services[0].id).processID == webPID)
            #expect(try hints.load().hints == before.hints)
        }
    }

    @Test("起動後の保存失敗では追加した1件だけを停止する")
    func failedPostSaveStopsOnlyAddedService() async throws {
        try await withProject { state, project, hints, directory in
            try await startEnvironment(state, project)
            let webPID = try #require(state.state(of: project.services[0].id).processID)
            // 操作前の保存は成功し、その次の保存だけ失敗させる。
            let postSave = hints.saveAttempts + 2
            hints.failSaves { $0 == postSave }
            state.startService(project.services[1], in: project)
            await state.waitForPendingOperation()
            #expect(state.operationError?.contains("だけを停止") == true)
            #expect(state.state(of: project.services[1].id).phase == .excluded)
            #expect(state.state(of: project.services[1].id).processID == nil)
            #expect(state.state(of: project.services[0].id).processID == webPID)
            #expect(state.phase(of: project) == .running)
            #expect(try hints.load().hints.map(\.serviceID) == [project.services[0].id])
            #expect(try ProjectStore(directory: directory).load() == [project])
        }
    }

    @Test("停止中の環境と二重操作はAppStateの入口でも拒否する")
    func rejectsStoppedAndConcurrentOperations() async throws {
        try await withProject { state, project, hints, _ in
            let inngest = project.services[1]
            #expect(!state.canStartService(inngest, in: project))
            state.startService(inngest, in: project)
            #expect(state.operationError?.contains("開発環境単位") == true)
            #expect(state.serviceOperation == nil)
            state.operationError = nil
            try await startEnvironment(state, project)

            state.startService(inngest, in: project)
            let operation = state.serviceOperation
            state.startService(inngest, in: project)
            #expect(state.operationError != nil)
            #expect(state.serviceOperation == operation)
            await state.waitForPendingOperation()
            #expect(state.state(of: inngest.id).phase == .healthy)
            #expect(try hints.load().hints.filter { $0.serviceID == inngest.id }.count == 1)
        }
    }

    @Test("再起動したアプリでも追加起動のプロセスを実測して引き継ぎ、全体停止できる")
    func restoresAddedProcessWithoutEnablingNextStart() async throws {
        try await withProject { state, project, _, directory in
            let inngest = project.services[1]
            try await startEnvironment(state, project)
            state.startService(inngest, in: project)
            await state.waitForPendingOperation()
            let originalPID = try #require(state.state(of: inngest.id).processID)

            // 別のRegistryでディスク上の手掛かりを再検証する。
            let restored = makeAppState(directory: directory)
            await restored.bootstrap()
            let presentation = try #require(restored.handoffPresentation)
            #expect(presentation.review.candidates.contains { $0.hint.serviceID == inngest.id })
            restored.performHandoffAction(.adopt, presentationID: presentation.id)
            await restored.waitForPendingOperation()
            #expect(restored.operationError == nil)
            #expect(restored.state(of: inngest.id).phase == .healthy)
            #expect(restored.state(of: inngest.id).processID == originalPID)
            #expect(restored.canRestart(inngest, in: project))
            #expect(restored.phase(of: project) == .running)
            #expect(restored.projects == [project])

            restored.stopProject(project)
            await restored.waitForPendingOperation()
            #expect(restored.operationError == nil)
            #expect(restored.state(of: inngest.id).phase == .excluded)
            #expect(!restored.hasManagedResources(in: project))
            #expect(try RuntimeHintStore(directory: directory).load().hints.isEmpty)
            #expect(try ProjectStore(directory: directory).load() == [project])
        }
    }
}
