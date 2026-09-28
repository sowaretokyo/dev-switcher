import Darwin
@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("引き継いだプロセスのログ")
@MainActor
struct AppStateHandoffLogTests {
    @Test("保存済みの手掛かりから実プロセスを引き継ぎ、同じPIDの追加出力を受け取る")
    func followsRealProcessAfterRelaunch() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
            printf 'before-out\\n'
            printf 'before-err\\n' >&2
            touch ready
            while [ ! -f continue ]; do sleep 0.05; done
            printf 'after-out\\n'
            printf 'after-err\\n' >&2
            while true; do sleep 0.1; done
            """
        let project = makeWorkerProject(directory: directory, arguments: ["-c", script], executable: "/bin/sh")
        let service = project.services[0]
        let files = try makeLogFiles(directory: directory, serviceID: service.id)
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script], workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(standardOutput: files.standardOutput, standardError: files.standardError)
        )
        let cleanup = TestProcessGroupCleanup(spawned)
        defer { #expect(cleanup.cleanUp()) }
        try #require(await waitForCondition {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
        })
        let hint = try #require(makeMeasuredHint(
            project: project, pid: spawned.pid, processGroupID: spawned.processGroupID, directory: directory
        ))
        try ProjectStore(directory: directory).save([project])
        try RuntimeHintStore(directory: directory).save([hint])

        let restored = makeAppState(directory: directory)
        await restored.bootstrap()
        let presentation = try #require(restored.handoffPresentation)
        restored.performHandoffAction(.adopt, presentationID: presentation.id)
        await restored.waitForPendingOperation()
        let buffer = restored.logBuffer(of: service.id)
        #expect(await waitForCondition { buffer.lines.count == 2 })
        #expect(restored.state(of: service.id).processID == spawned.pid)
        #expect(restored.state(of: service.id).logError == nil)

        try Data().write(to: directory.appendingPathComponent("continue"))
        #expect(await waitForCondition { buffer.lines.count == 4 })
        #expect(buffer.lines.filter { $0.stream == .stdout }.map(\.text) == ["before-out", "after-out"])
        #expect(buffer.lines.filter { $0.stream == .stderr }.map(\.text) == ["before-err", "after-err"])
        #expect(restored.state(of: service.id).processID == spawned.pid)

        restored.stopProject(project)
        await restored.waitForPendingOperation()
        #expect(restored.operationError == nil)
        #expect(restored.phase(of: project) == .stopped)
    }

    @Test("プロセスを再起動せず、保存済みログと引き継ぎ後の出力を表示する")
    func restoresAndFollowsLogs() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = makeSyntheticFixture(directory: directory)
        let files = try makeLogFiles(directory: directory, serviceID: fixture.service.id)
        try Data("before-out\n".utf8).write(to: files.standardOutput)
        try Data("before-err\n".utf8).write(to: files.standardError)

        let state = try await adopt(fixture, directory: directory)
        let buffer = state.logBuffer(of: fixture.service.id)
        #expect(await waitForCondition { buffer.lines.count == 2 })
        #expect(state.state(of: fixture.service.id).logError == nil)
        #expect(fixture.signals.sent.isEmpty)

        try append("after-out\npartial", to: files.standardOutput)
        try append("after-err\n", to: files.standardError)
        #expect(await waitForCondition { buffer.lines.count == 4 })
        #expect(buffer.lines.filter { $0.stream == .stdout }.map(\.text) == ["before-out", "after-out"])
        #expect(buffer.lines.filter { $0.stream == .stderr }.map(\.text) == ["before-err", "after-err"])
        #expect(buffer.stderrCount == 2)
        #expect(Set(buffer.lines.map(\.id)).count == buffer.lines.count)

        state.stopProject(fixture.project)
        await state.waitForPendingOperation()
        #expect(await waitForCondition { buffer.lines.last?.text == "partial" })
        #expect(state.phase(of: fixture.project) == .stopped)
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])

        // 追尾停止後の追記は、次の起動のログへ混入させない。
        try append("must-not-appear\n", to: files.standardOutput)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!buffer.lines.contains { $0.text.contains("must-not-appear") })
    }

    @Test("ログが欠落・不正でも理由を表示し、引き継いだプロセスは停止できる", arguments: ["stdout", "stderr", "directory"])
    func reportsUnreadableLogsWithoutLosingControl(failure: String) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = makeSyntheticFixture(directory: directory)
        let files = try makeLogFiles(directory: directory, serviceID: fixture.service.id)
        let invalidURL = failure == "stderr" ? files.standardError : files.standardOutput
        try FileManager.default.removeItem(at: invalidURL)
        if failure == "directory" {
            try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: false)
        }

        let state = try await adopt(fixture, directory: directory)
        #expect(await waitForCondition { state.state(of: fixture.service.id).logError != nil })
        #expect(state.state(of: fixture.service.id).logError?.contains(invalidURL.path) == true)
        #expect(state.logBuffer(of: fixture.service.id).lines.isEmpty)
        #expect(state.canStop)
        #expect(fixture.signals.sent.isEmpty)

        await state.applicationDidBecomeActive()
        #expect(state.state(of: fixture.service.id).logError != nil)
        state.stopProject(fixture.project)
        await state.waitForPendingOperation()
        #expect(state.operationError == nil)
        #expect(state.phase(of: fixture.project) == .stopped)
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
    }

    private func adopt(_ fixture: SyntheticFixture, directory: URL) async throws -> AppState {
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])
        let state = makeAppState(
            directory: directory, registry: fixture.registry, handoffInspector: fixture.inspector
        )
        await state.bootstrap()
        let presentation = try #require(state.handoffPresentation)
        state.performHandoffAction(.adopt, presentationID: presentation.id)
        await state.waitForPendingOperation()
        #expect(state.operationError == nil)
        #expect(state.phase(of: fixture.project) == .running)
        return state
    }

    private func makeLogFiles(directory: URL, serviceID: UUID) throws -> ServiceLogFiles {
        let logDirectory = directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let files = ServiceLogFiles(directory: logDirectory, serviceID: serviceID)
        try Data().write(to: files.standardOutput)
        try Data().write(to: files.standardError)
        return files
    }

    private func append(_ text: String, to url: URL) throws {
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(text.utf8))
    }
}
