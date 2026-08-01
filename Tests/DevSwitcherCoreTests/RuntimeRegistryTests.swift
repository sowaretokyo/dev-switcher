import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("起動・停止の入り口")
struct RuntimeRegistryTests {
    @Test("環境の PATH からコマンド名を解決して起動する")
    func startsServiceResolvedFromEnvironmentPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let service = makeService(
            name: "Echo",
            kind: .other,
            ports: [],
            executable: "echo",
            arguments: ["registry"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        let log = EventLog()
        let stream = try await registry.start(service: service, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await log.exitStatus == .exited(code: 0))
        #expect(await log.text(of: .stdout).contains("registry"))
    }

    @Test("存在しないコマンドは起動前に失敗させる")
    func missingExecutableFailsBeforeLaunch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let service = makeService(
            executable: "definitely-not-installed-command",
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        await #expect(throws: ExecutableResolutionError.self) {
            _ = try await registry.start(service: service, in: project)
        }
    }

    @Test("プロジェクトのディレクトリが無ければ起動しない")
    func missingProjectDirectoryFails() async throws {
        let directory = try makeTemporaryDirectory()
        let service = makeService(workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        try FileManager.default.removeItem(at: directory)

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: service, in: project)
        }
    }

    @Test("起動していないサービスの停止を受け付けない")
    func stopWithoutStartFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let service = makeService(workingDirectory: directory)

        await #expect(throws: RuntimeError.self) {
            _ = try await registry.stop(service: service)
        }
    }

    @Test("別プロジェクトが稼働中なら起動しない")
    func doesNotStartSecondProject() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let sleepCommand: (String) -> ServiceDefinition = { name in
            makeService(
                name: name,
                kind: .worker,
                ports: [],
                executable: "/bin/sleep",
                arguments: ["30"],
                workingDirectory: directory
            )
        }

        let serviceA = sleepCommand("A")
        let projectA = makeProject(name: "Bell", directory: directory, services: [serviceA])
        let serviceB = sleepCommand("B")
        let projectB = makeProject(name: "Penta", directory: directory, services: [serviceB])

        let log = EventLog()
        let stream = try await registry.start(service: serviceA, in: projectA)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.startedRuntime != nil })
        #expect(await registry.runningProjectID() == projectA.id)

        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: serviceB, in: projectB)
        }

        _ = try await registry.stop(service: serviceA, grace: .seconds(5))
        #expect(await registry.runningProjectID() == nil)

        let streamB = try await registry.start(service: serviceB, in: projectB)
        let logB = EventLog()
        let consumerB = Task { await logB.consume(streamB) }
        defer { consumerB.cancel() }
        #expect(await waitUntil { await logB.startedRuntime != nil })
        _ = try await registry.stop(service: serviceB, grace: .seconds(5))
    }

    @Test("停止しきれず残ったプロセスがある間も別プロジェクトを起動しない")
    func residualProcessesBlockOtherProject() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        // SIGTERM を無視し続ける固定コマンド（利用者入力ではない）。
        let stubborn = makeService(
            name: "Stubborn",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"],
            workingDirectory: directory
        )
        let projectA = makeProject(name: "Bell", directory: directory, services: [stubborn])
        let serviceB = makeService(
            name: "B",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let projectB = makeProject(name: "Penta", directory: directory, services: [serviceB])

        let log = EventLog()
        let stream = try await registry.start(service: stubborn, in: projectA)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }
        #expect(await waitUntil { await log.startedRuntime != nil })

        let outcome = try await registry.stop(service: stubborn, grace: .milliseconds(800))
        guard case .residual = outcome else {
            Issue.record("残存として扱われなかった: \(outcome)")
            _ = try? await registry.forceStop(service: stubborn)
            return
        }

        #expect(await registry.runningProjectID() == projectA.id)
        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: serviceB, in: projectB)
        }

        _ = try await registry.forceStop(service: stubborn)
        #expect(await registry.runningProjectID() == nil)
    }

    @Test("親が先に終了して孫だけ残る場合も占有中として扱う")
    func detachedGrandchildBlocksOtherProject() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let detached = makeService(
            name: "Detached",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "sleep 120 &"],
            workingDirectory: directory
        )
        let projectA = makeProject(name: "Bell", directory: directory, services: [detached])
        let serviceB = makeService(
            name: "B",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let projectB = makeProject(name: "Penta", directory: directory, services: [serviceB])

        let log = EventLog()
        let stream = try await registry.start(service: detached, in: projectA)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await registry.runningProjectID() == projectA.id)
        #expect(await registry.occupiedProcessGroup(serviceID: detached.id) != nil)

        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: serviceB, in: projectB)
        }

        let outcome = try await registry.stop(service: detached, grace: .seconds(5))
        guard case .exited = outcome else {
            Issue.record("孫プロセスを停止できなかった: \(outcome)")
            _ = try? await registry.forceStop(service: detached)
            return
        }
        #expect(await registry.runningProjectID() == nil)

        let streamB = try await registry.start(service: serviceB, in: projectB)
        let logB = EventLog()
        let consumerB = Task { await logB.consume(streamB) }
        defer { consumerB.cancel() }
        #expect(await waitUntil { await logB.startedRuntime != nil })
        _ = try await registry.stop(service: serviceB, grace: .seconds(5))
    }

    @Test("孫が残っている間は同じサービスも再起動しない")
    func doesNotRestartServiceWhileProcessesRemain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let detached = makeService(
            name: "Detached",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "sleep 120 &"],
            workingDirectory: directory
        )
        let project = makeProject(name: "Bell", directory: directory, services: [detached])

        let log = EventLog()
        let stream = try await registry.start(service: detached, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        let processGroupID = try #require(
            await registry.occupiedProcessGroup(serviceID: detached.id)
        )

        // ここで起動を許すと、supervisor が差し替わって残ったグループを見失う。
        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: detached, in: project)
        }
        #expect(await registry.occupiedProcessGroup(serviceID: detached.id) == processGroupID)

        let outcome = try await registry.stop(service: detached, grace: .seconds(5))
        guard case .exited = outcome else {
            Issue.record("残ったプロセスを停止できなかった: \(outcome)")
            _ = try? await registry.forceStop(service: detached)
            return
        }
        #expect(await registry.occupiedProcessGroup(serviceID: detached.id) == nil)

        let restarted = try await registry.start(service: detached, in: project)
        let restartedLog = EventLog()
        let restartedConsumer = Task { await restartedLog.consume(restarted) }
        defer { restartedConsumer.cancel() }
        #expect(await waitUntil { await restartedLog.exitStatus != nil })
        _ = try? await registry.stop(service: detached, grace: .seconds(5))
    }

    @Test("起動中のサービスを二重に起動しない")
    func doesNotStartTwice() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment }
        )
        let service = makeService(
            name: "Sleep",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        let log = EventLog()
        let stream = try await registry.start(service: service, in: project)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.startedRuntime != nil })

        await #expect(throws: RuntimeError.self) {
            _ = try await registry.start(service: service, in: project)
        }

        let outcome = try await registry.stop(service: service, grace: .seconds(5))
        #expect(outcome == .exited(.signaled(signal: SIGTERM)))
    }
}
