import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("通常プロセスの停止コマンド")
struct ProcessStopCommandTests {
    private func service(_ directory: URL, stopScript: String) -> LaunchUnit {
        makeService(kind: .worker, ports: [], executable: "/bin/bash", arguments: ["-c", "echo start-output; trap 'echo term >> term; exit 0' TERM; while [ ! -f finished ]; do sleep 0.02; done; exit 0"], workingDirectory: directory,
            stop: CommandSpec(executable: "/bin/bash", arguments: ["-c", stopScript], workingDirectory: directory))
    }
    @Test("停止コマンドで対象を停止し、対象へ SIGTERM を送らず、失敗を結果とログに残す")
    func commandStopsTarget() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(directory, stopScript: "echo stop-output; echo stop-error >&2; touch finished; exit 7")
        let project = makeProject(directory: directory, services: [service])
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
        _ = try await registry.start(service: service, in: project)
        do {
            let result = try await registry.stop(service: service, grace: .seconds(2))
            guard case let .stopped(_, warning) = result else { Issue.record("停止できませんでした: \(result)"); _ = try await registry.forceStop(service: service); return }
            #expect(warning?.contains("失敗") == true)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("term").path))
            #expect(await registry.isOccupyingResources(serviceID: service.id) == false)
            let files = ServiceLogFiles(directory: directory, serviceID: service.id)
            #expect(try String(contentsOf: files.standardOutput, encoding: .utf8).contains("stop-output"))
            #expect(try String(contentsOf: files.standardError, encoding: .utf8).contains("停止コマンドが失敗"))
        } catch { _ = try await registry.forceStop(service: service); throw error }
    }
    @Test("対象グループが空なら停止コマンドを実行しない")
    func skipsCommandForGoneTarget() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var service = service(directory, stopScript: "touch should-not-run")
        service.start.arguments = ["-c", "exit 0"]
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
        _ = try await registry.start(service: service, in: makeProject(directory: directory, services: [service]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await registry.stop(service: service).isStopped)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-run").path))
    }
    @Test("停止コマンドがタイムアウトしても SIGKILL せず、残存を別の手掛かりとして保存する")
    func timeoutPreservesBothGroups() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(directory, stopScript: "trap '' TERM; while true; do sleep 0.02; done")
        let project = makeProject(directory: directory, services: [service])
        let registry = RuntimeRegistry(stopCommandTimeout: .milliseconds(100), logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
        _ = try await registry.start(service: service, in: project)
        do {
            let outcome = try await registry.stop(service: service, grace: .milliseconds(100))
            #expect(!outcome.isStopped)
            let hints = try await registry.runtimeHints()
            #expect(hints.count == 2)
            let auxiliary = try #require(hints.first(where: { $0.stopCommandFor == service.id }))
            #expect(auxiliary.serviceID != service.id)
            #expect(auxiliary.stopCommand == service.stop)
            #expect(project.runtimeEntry(for: auxiliary) != nil)
            #expect(await registry.occupyingServiceIDs(projectID: project.id) == [service.id])
            let store = RuntimeHintStore(directory: directory)
            try store.save(hints, legacy: [], managed: [])
            #expect(try store.load().hints == hints)
            let review = await HandoffInspector(bootSessionProbe: { "STOP-COMMAND-TEST" }).review(RuntimeHintsLoad(hints: hints))
            #expect(review.stoppable.contains { $0.hint.serviceID == auxiliary.serviceID })
            #expect(review.candidates.allSatisfy { $0.hint.serviceID != auxiliary.serviceID })
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("term").path))
            #expect(try await registry.forceStop(service: service, grace: .seconds(2)).isStopped)
            #expect(await registry.isOccupyingResources(serviceID: service.id) == false)
        } catch { _ = try await registry.forceStop(service: service, grace: .seconds(2)); throw error }
    }
    @Test("引き継いだプロセスも停止コマンドで停止する")
    func adoptedCommandStop() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(directory, stopScript: "touch finished")
        let project = makeProject(directory: directory, services: [service])
        let original = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
        _ = try await original.start(service: service, in: project)
        do {
            try await original.refreshPorts(serviceID: service.id)
            let hints = try await original.runtimeHints()
            let hint = try #require(hints.first)
            #expect(ProcessInspector.startAbstimeObservation(pid: hint.leader.pid).value == hint.leader.startAbstime)
            #expect(ProcessInspector.executablePath(pid: hint.leader.pid) == hint.executablePath)
            #expect(ProcessInspector.workingDirectory(pid: hint.leader.pid)?.standardizedFileURL.path == hint.workingDirectory.standardizedFileURL.path)
            #expect(hint.groupEvidence.bootSessionID == "STOP-COMMAND-TEST")
            let review = await HandoffInspector(bootSessionProbe: { "STOP-COMMAND-TEST" }).review(RuntimeHintsLoad(hints: hints))
            let candidate = try #require(review.candidates.first, "\(review.stoppable.map(\.reason)) / \(review.rejected.map { $0.reason.description })")
            let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
            let coordinator = SwitchCoordinator(registry: registry)
            #expect(try await coordinator.stopAdopted(candidate, service: service, in: project).isStopped)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("term").path))
            _ = try await original.forceStop(service: service)
        } catch { _ = try await original.forceStop(service: service); throw error }
    }
}

private actor StopCommandLogRecorder {
    var texts: [String] = []
    func consume(_ events: AsyncStream<ServiceSupervisor.Event>) async {
        for await event in events {
            if case let .log(lines) = event { texts += lines.map(\.text) }
        }
    }
}

extension ProcessStopCommandTests {
    @Test("対象が先に終了しても、停止コマンドの末尾ログまで受け取る")
    func trailingStopOutputIsDelivered() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let process = service(directory, stopScript: "touch finished; sleep 0.7; echo late-stop-output")
        let project = makeProject(directory: directory, services: [process])
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment })
        let stream = try await registry.start(service: process, in: project)
        let recorder = StopCommandLogRecorder()
        let consumer = Task { await recorder.consume(stream) }
        do {
            #expect(try await registry.stop(service: process, grace: .seconds(2)).isStopped)
            await consumer.value
            #expect(await recorder.texts.contains("start-output"))
            #expect(await recorder.texts.contains("late-stop-output"))
        } catch {
            consumer.cancel()
            _ = try await registry.forceStop(service: process)
            throw error
        }
    }
}

extension ProcessStopCommandTests {
    @Test("対象終了後も残る停止コマンドの PGID を表示し、親の停止操作から回収できる")
    func onlyStopCommandRemains() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let process = service(directory, stopScript: "trap '' TERM; touch finished; while true; do sleep 0.02; done")
        let project = makeProject(directory: directory, services: [process])
        let registry = RuntimeRegistry(stopCommandTimeout: .milliseconds(100), logDirectory: directory, environmentLoader: { fixedShellEnvironment }, bootSessionProbe: { "STOP-COMMAND-TEST" })
        _ = try await registry.start(service: process, in: project)
        do {
            let outcome = try await registry.stop(service: process, grace: .milliseconds(100))
            guard case let .residual(pgid, _) = outcome else { Issue.record("停止コマンドの残存が返りませんでした"); return }
            let snapshot = try #require(await registry.runtimeSnapshot(serviceID: process.id))
            #expect(snapshot.processID == nil)
            #expect(snapshot.processGroupID == pgid)
            #expect(await registry.isOccupyingResources(serviceID: process.id))
            let hints = try await registry.runtimeHints()
            await #expect(throws: RuntimeError.self) { try await registry.start(service: process, in: project) }
            #expect(hints.count == 1)
            #expect(hints[0].stopCommandFor == process.id)
            #expect(try await registry.forceStop(service: process, grace: .seconds(2)).isStopped)
            #expect(await registry.isOccupyingResources(serviceID: process.id) == false)
        } catch { _ = try await registry.forceStop(service: process, grace: .seconds(2)); throw error }
    }
}
