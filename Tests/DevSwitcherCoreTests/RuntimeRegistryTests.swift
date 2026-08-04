import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("起動・停止の入り口")
struct RuntimeRegistryTests {
    @Test("低水準の引き継ぎ入力もRegistry登録直前に再検証する")
    func rejectsUntrustedLowLevelAdoptionInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = ProcessIdentity(
            pid: 100,
            startAbstime: 5_000,
            startedAt: Date(timeIntervalSince1970: 1),
            executablePath: "/bin/sleep",
            workingDirectory: directory
        )
        let evidence = ProcessGroupEvidence(
            bootSessionID: "TEST-BOOT-SESSION",
            anchors: [identity.anchor]
        )
        let service = makeService(
            name: "Adopted",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        let registry = RuntimeRegistry(
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 100, isZombie: false)])
            },
            startAbstimeProbe: { pid in pid == 100 ? .present(5_000) : .notPresent },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )

        await #expect(throws: RuntimeError.self) {
            try await registry.adopt(
                identity: identity,
                processGroupID: 101,
                observedPorts: [],
                evidence: evidence,
                service: service,
                in: project
            )
        }

        let unrelatedEvidence = ProcessGroupEvidence(
            bootSessionID: evidence.bootSessionID,
            anchors: [ProcessAnchor(pid: 101, startAbstime: 1)]
        )
        await #expect(throws: RuntimeError.self) {
            try await registry.adopt(
                identity: identity,
                processGroupID: 100,
                observedPorts: [],
                evidence: unrelatedEvidence,
                service: service,
                in: project
            )
        }

        let wrongBootEvidence = ProcessGroupEvidence(
            bootSessionID: "WRONG-BOOT-SESSION",
            anchors: [identity.anchor]
        )
        await #expect(throws: RuntimeError.self) {
            try await registry.adopt(
                identity: identity,
                processGroupID: 100,
                observedPorts: [],
                evidence: wrongBootEvidence,
                service: service,
                in: project
            )
        }
        #expect(await registry.occupiedProcessGroup(serviceID: service.id) == nil)
    }

    @Test("残存groupのhintにもポート観測不能を保存する")
    func residualHintStoresUnavailablePortObservation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let anchor = ProcessAnchor(pid: 100, startAbstime: 5_000)
        let evidence = ProcessGroupEvidence(
            bootSessionID: "TEST-BOOT-SESSION",
            anchors: [anchor]
        )
        let service = makeService(
            name: "Residual",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        let hint = RuntimeHint(
            projectID: project.id,
            serviceID: service.id,
            serviceName: service.name,
            processGroupID: 100,
            leader: anchor,
            groupEvidence: evidence,
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            observedPorts: .observed([3000])
        )
        let registry = RuntimeRegistry(
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in
                throw PortInspectorError.unparsableOutput(line: "broken")
            },
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 100, isZombie: false)])
            },
            startAbstimeProbe: { _ in .present(5_000) },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )

        try await registry.registerResidualGroup(hint: hint, service: service, in: project)
        await #expect(throws: PortInspectorError.self) {
            try await registry.refreshPorts(serviceID: service.id)
        }

        let hints = try await registry.runtimeHints()
        let stored = try #require(hints.first)
        #expect(stored.observedPorts == .unavailable)
        #expect(
            await registry.runtimeSnapshot(serviceID: service.id)?.observedPortRecord
                == .unavailable
        )
    }

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
        // trap を仕掛け終えたことをファイルで知らせる。仕掛かる前に停止すると、
        // 無視するはずのプロセスが素直に終了してしまい、検証したい状況にならない。
        let readyFile = directory.appendingPathComponent("stubborn.ready")
        let stubborn = makeService(
            name: "Stubborn",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; echo ready > \"\(readyFile.path)\"; while true; do sleep 1; done",
            ],
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
        #expect(await waitUntil { FileManager.default.fileExists(atPath: readyFile.path) })

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
        guard case .stopped = outcome else {
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
        guard case .stopped = outcome else {
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
        #expect(outcome == .stopped(.signaled(signal: SIGTERM)))
    }
}
