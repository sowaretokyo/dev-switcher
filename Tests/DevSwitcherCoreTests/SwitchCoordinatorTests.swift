import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("プロジェクトの起動・停止・切替")
struct SwitchCoordinatorTests {
    /// ヘルスチェックとポート実測を差し替えたスタック。
    /// 実プロセスの起動・停止・順序は本物のまま検証する。
    private func makeStack(
        logDirectory: URL,
        world: FakePortWorld? = nil,
        health: @escaping HealthProbe.HTTPRequest = { _ in .healthy(statusCode: 200) },
        options: SwitchCoordinator.Options = SwitchCoordinator.Options(
            releaseTimeout: .seconds(3),
            stopGrace: .seconds(5),
            healthTimeout: .seconds(5),
            healthObservationWindow: .milliseconds(200),
            healthPollInterval: .milliseconds(50),
            gatePollInterval: .milliseconds(50)
        )
    ) -> (RuntimeRegistry, SwitchCoordinator) {
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: logDirectory,
            environmentLoader: { fixedShellEnvironment }
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            healthProbe: HealthProbe(request: health),
            portHolderProbe: { ports in
                guard let world else { return [] }
                return try await world.probe(ports)
            },
            options: options,
            currentUserName: "test-user"
        )
        return (registry, coordinator)
    }

    @Test("複数サービスを設定順に起動する")
    func startsServicesInConfiguredOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let services = ["Supabase", "Web", "Inngest"].map {
            makeOrderedService(
                name: $0,
                workingDirectory: directory,
                startLog: startLog,
                stopLog: stopLog
            )
        }
        let project = makeProject(directory: directory, services: services)
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)
        defer { Task { _ = try? await coordinator.stop(project) } }

        #expect(readLines(startLog) == ["Supabase", "Web", "Inngest"])
        #expect(outcome.degradedServices.isEmpty)
        #expect(outcome.facts.target?.phase == .running)

        _ = try await coordinator.stop(project)
    }

    @Test("既定の終了順は起動順の逆")
    func stopsServicesInReverseOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let services = ["Supabase", "Web", "Inngest"].map {
            makeOrderedService(
                name: $0,
                workingDirectory: directory,
                startLog: startLog,
                stopLog: stopLog
            )
        }
        let project = makeProject(directory: directory, services: services)
        let (_, coordinator) = makeStack(logDirectory: directory)

        _ = try await coordinator.start(project)
        // trap を仕掛けたあとに書かれる起動ログを待つ。仕掛かる前に停止すると、
        // 終了順を記録しないまま終わってしまう。
        #expect(await waitUntil { readLines(startLog).count == 3 })

        let outcome = try await coordinator.stop(project)

        #expect(readLines(stopLog) == ["Inngest", "Web", "Supabase"])
        #expect(outcome.facts.source?.phase == .stopped)
    }

    @Test("終了順を明示指定した場合は既定の逆順ではなくその順で停止する")
    func stopsServicesInExplicitOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let services = ["A", "B", "C"].map {
            makeOrderedService(
                name: $0,
                workingDirectory: directory,
                startLog: startLog,
                stopLog: stopLog
            )
        }
        let project = makeProject(
            directory: directory,
            services: services,
            stopOrder: [services[1].id, services[0].id, services[2].id]
        )
        let (_, coordinator) = makeStack(logDirectory: directory)

        _ = try await coordinator.start(project)
        #expect(await waitUntil { readLines(startLog).count == 3 })

        _ = try await coordinator.stop(project)

        #expect(readLines(stopLog) == ["B", "A", "C"])
    }

    @Test("起動対象外のサービスを起動せず、一部停止としても扱わない")
    func doesNotStartExcludedServices() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let services = ["Web", "Expo"].map {
            makeOrderedService(
                name: $0,
                workingDirectory: directory,
                startLog: startLog,
                stopLog: stopLog
            )
        }
        let project = makeProject(
            directory: directory,
            services: services,
            enabledNow: [services[1].id: false]
        )
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(readLines(startLog) == ["Web"])
        // 対象外は警告でも一部停止でもない。プロジェクトは稼働中。
        #expect(outcome.degradedServices.isEmpty)
        #expect(outcome.facts.target?.phase == .running)

        let excluded = try #require(
            outcome.facts.target?.services.first { $0.serviceID == services[1].id }
        )
        #expect(excluded.phase == .excluded)

        _ = try await coordinator.stop(project)
    }

    @Test("failurePolicy: block の起動失敗では、今回起動したサービスを停止して後続を起動しない")
    func blockPolicyStopsStartedServicesAndHalts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let first = makeOrderedService(
            name: "First",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let broken = makeFailingService(
            name: "Broken",
            workingDirectory: directory,
            failurePolicy: .block
        )
        let last = makeOrderedService(
            name: "Last",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [first, broken, last])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }

        // 後続は起動していない。今回起動した First は巻き戻しで停止している。
        #expect(readLines(startLog) == ["First"])
        #expect(readLines(stopLog) == ["First"])
        #expect(await registry.isRunning(serviceID: first.id) == false)
        #expect(await registry.isRunning(serviceID: last.id) == false)
    }

    @Test("failurePolicy: continue の起動失敗では後続を起動し、一部停止として扱う")
    func continuePolicyKeepsGoingAndReportsDegraded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let first = makeOrderedService(
            name: "First",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let flaky = makeFailingService(
            name: "Flaky",
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let last = makeOrderedService(
            name: "Last",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [first, flaky, last])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(readLines(startLog) == ["First", "Last"])
        #expect(outcome.degradedServices == ["Flaky"])
        #expect(outcome.facts.target?.phase == .degraded(stoppedServices: ["Flaky"]))

        _ = try await coordinator.stop(project)
    }

    @Test("停止側の実測ポートが解放されるまで、起動側の検証へ進まない")
    func doesNotProceedUntilSourcePortsAreReleased() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        // 空きポート番号だけを取り、実際の listen は停止元のサービス自身にさせる。
        // ゲート1の対象は設定値ではなく、そのプロセスの実測ポートから決まる。
        let reserved = try LocalTCPServer(behavior: .silent)
        let sourcePort = reserved.port
        reserved.stop()

        let world = FakePortWorld()

        let sourceService = makeService(
            name: "Holder",
            kind: .worker,
            ports: [PortSpec(port: sourcePort, isPrimary: true)],
            executable: "/usr/bin/nc",
            arguments: ["-l", String(sourcePort)],
            workingDirectory: directory
        )
        let source = makeProject(name: "Bell", directory: directory, services: [sourceService])

        let targetService = makeOrderedService(
            name: "Target",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let target = makeProject(name: "Penta", directory: directory, services: [targetService])

        let (registry, coordinator) = makeStack(logDirectory: directory, world: world)

        _ = try await coordinator.start(source)
        // 実測できるようになるまで待つ。設定値ではなく実測をゲートの対象にしている。
        #expect(await waitUntil {
            let holders = try? await PortInspector.holders(ofPorts: [sourcePort])
            return holders?.isEmpty == false
        })

        // 停止したあともポートが握られたままの状況を作る。
        await world.occupy(port: sourcePort, pid: 999_001, command: "leftover")

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.switchProject(from: source, to: target)
        }

        // 起動側の検証にも起動にも進んでいない。
        #expect(readLines(startLog).isEmpty)
        #expect(await registry.isRunning(serviceID: targetService.id) == false)
        if let failure {
            guard case let .portsNotReleased(holders) = failure.reason else {
                Issue.record("ゲート1以外で失敗した: \(failure.reason)")
                return
            }
            #expect(holders.map(\.port) == [sourcePort])
            // 失敗時は切替元と切替先の現在状態を必ず返す。
            #expect(failure.facts.source != nil)
            #expect(failure.facts.target != nil)
        }

        // ゲート2の実測が行われていないことを、問い合わせたポート集合から確かめる。
        let probedSets = await world.probedPortSets
        #expect(probedSets.allSatisfy { $0 == [sourcePort] })

        _ = try? await coordinator.stop(source)
    }

    @Test("起動側の設定ポートが空くまで、サービスを1つも起動しない")
    func doesNotStartAnyServiceWhenTargetPortIsTaken() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let world = FakePortWorld()
        // 2番目のサービスのポートだけが埋まっている状況。
        await world.occupy(port: 3101, pid: 999_002, command: "other-project")

        let first = makeOrderedService(
            name: "First",
            ports: [PortSpec(port: 3100, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let second = makeOrderedService(
            name: "Second",
            ports: [PortSpec(port: 3101, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [first, second])
        let (_, coordinator) = makeStack(logDirectory: directory, world: world)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }

        // 1つ目のポートが空いていても、1つも起動しない。
        #expect(readLines(startLog).isEmpty)
        if let failure {
            guard case let .portConflict(holders) = failure.reason else {
                Issue.record("ポート競合として扱われなかった: \(failure.reason)")
                return
            }
            #expect(holders.map(\.port) == [3101])
            // failurePolicy: continue のサービスのポートもゲートの対象にする。
            #expect(holders.first?.ownership == .systemOwned)
        }
    }

    @Test("listen 開始だけでは稼働中にせず、ヘルスチェック通過を待つ")
    func listeningAloneIsNotHealthy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 応答しない HTTP プローブ。listen していても利用可能とは扱わない。
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            health: { _ in .unreachable(reason: "接続できません") },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .seconds(5),
                healthTimeout: .milliseconds(600),
                healthObservationWindow: .milliseconds(200),
                healthPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        let web = makeService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: 3200, isPrimary: true)],
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 0.1; done"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [web])

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }

        if let failure {
            guard case let .startFailed(service, reason) = failure.reason else {
                Issue.record("起動失敗として扱われなかった: \(failure.reason)")
                return
            }
            #expect(service == "Web")
            // プロセスは生きていた。落ちたのではなくヘルスチェックが通らなかった。
            #expect(reason.contains("ヘルスチェック"))
            #expect(!reason.contains("起動直後に終了"))
        }
    }

    @Test("起動前までの中止では切替元の停止を完了し、切替先を起動しない")
    func cancelBeforeStartPhaseStopsSourceOnly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let sourceService = makeOrderedService(
            name: "Source",
            ports: [PortSpec(port: 3300, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let source = makeProject(name: "Bell", directory: directory, services: [sourceService])
        let targetService = makeOrderedService(
            name: "Target",
            ports: [PortSpec(port: 3301, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let target = makeProject(name: "Penta", directory: directory, services: [targetService])

        let world = FakePortWorld()
        let gate = TestGate()

        let (registry, coordinator) = makeStack(logDirectory: directory, world: world)
        _ = try await coordinator.start(source)
        #expect(await waitUntil { readLines(startLog) == ["Source"] })

        // 切替元を起動し終えてから仕掛ける。ゲートの検証に入った時点で中止できることを確かめる。
        await world.setOnProbe { [gate] in
            await gate.markReached()
            await gate.waitForRelease()
        }

        let switchTask = Task {
            try await coordinator.switchProject(from: source, to: target)
        }

        #expect(await gate.waitUntilReached())
        #expect(await coordinator.cancel())
        await gate.release()

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await switchTask.value
        }
        if let failure {
            #expect(failure.reason == .cancelled)
        }

        // 切替元の停止は完了し、切替先は起動していない。
        #expect(await waitUntil { readLines(stopLog) == ["Source"] })
        #expect(readLines(startLog) == ["Source"])
        #expect(await registry.isRunning(serviceID: targetService.id) == false)
    }

    @Test("起動フェーズに入ったあとは中止を受け付けない")
    func cancelIsRejectedAfterStartPhase() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let gate = TestGate()
        let service = makeOrderedService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: 3400, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [service])

        // ヘルスチェック中（＝起動フェーズ内）で止めて、中止が拒否されることを見る。
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            health: { [gate] _ in
                await gate.markReached()
                await gate.waitForRelease()
                return .healthy(statusCode: 200)
            }
        )

        let startTask = Task { try await coordinator.start(project) }
        #expect(await gate.waitUntilReached())
        #expect(await coordinator.cancel() == false)
        await gate.release()

        _ = try await startTask.value
        #expect(await waitUntil { readLines(startLog) == ["Web"] })

        _ = try await coordinator.stop(project)
    }

    @Test("切替は停止・ゲート1・ゲート2・起動の順に進む")
    func switchFollowsStopGateStartOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let sourceService = makeOrderedService(
            name: "Source",
            ports: [PortSpec(port: 3500, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let source = makeProject(name: "Bell", directory: directory, services: [sourceService])
        let targetService = makeOrderedService(
            name: "Target",
            ports: [PortSpec(port: 3501, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let target = makeProject(name: "Penta", directory: directory, services: [targetService])

        let world = FakePortWorld()
        let (_, coordinator) = makeStack(logDirectory: directory, world: world)

        _ = try await coordinator.start(source)

        let recorder = ProgressRecorder()
        let outcome = try await coordinator.switchProject(
            from: source,
            to: target,
            progress: { state in recorder.append(state) }
        )

        let states = recorder.states
        let stopIndex = states.firstIndex { if case .stopping = $0 { return true } else { return false } }
        let releaseIndex = states.firstIndex { if case .verifyingRelease = $0 { return true } else { return false } }
        let acquireIndex = states.firstIndex { if case .verifyingAcquire = $0 { return true } else { return false } }
        let startIndex = states.firstIndex { if case .starting = $0 { return true } else { return false } }

        #expect(stopIndex != nil)
        #expect(releaseIndex != nil)
        #expect(acquireIndex != nil)
        #expect(startIndex != nil)
        if let stopIndex, let releaseIndex, let acquireIndex, let startIndex {
            #expect(stopIndex < releaseIndex)
            #expect(releaseIndex < acquireIndex)
            #expect(acquireIndex < startIndex)
        }

        #expect(readLines(startLog) == ["Source", "Target"])
        #expect(readLines(stopLog) == ["Source"])
        #expect(outcome.facts.source?.phase == .stopped)
        #expect(outcome.facts.target?.phase == .running)

        _ = try await coordinator.stop(target)
    }

    @Test("同時に2つの切替を開始できない")
    func rejectsConcurrentOperations() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let gate = TestGate()
        let service = makeOrderedService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: 3600, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [service])
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            health: { [gate] _ in
                await gate.markReached()
                await gate.waitForRelease()
                return .healthy(statusCode: 200)
            }
        )

        let first = Task { try await coordinator.start(project) }
        #expect(await gate.waitUntilReached())

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }
        if let failure {
            #expect(failure.reason == .operationInProgress)
        }

        await gate.release()
        _ = try await first.value
        _ = try await coordinator.stop(project)
    }

    @Test("Milestone 2 で実行できない設定は、停止を始める前に失敗させる")
    func unsupportedConfigurationFailsBeforeStopping() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let sourceService = makeOrderedService(
            name: "Source",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let source = makeProject(name: "Bell", directory: directory, services: [sourceService])

        // 終了コマンドを持つサービス（managed command）は Milestone 3。
        let managed = makeService(
            name: "Supabase",
            kind: .supabase,
            ports: [PortSpec(label: "API", port: 54_321, isPrimary: true)],
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 0.1; done"],
            workingDirectory: directory,
            stop: CommandSpec(
                executable: "/bin/echo",
                arguments: ["stop"],
                workingDirectory: directory
            )
        )
        let target = makeProject(name: "Penta", directory: directory, services: [managed])
        let (_, coordinator) = makeStack(logDirectory: directory)

        _ = try await coordinator.start(source)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.switchProject(from: source, to: target)
        }
        if let failure {
            guard case .unsupportedConfiguration = failure.reason else {
                Issue.record("未対応設定として扱われなかった: \(failure.reason)")
                return
            }
        }

        // 停止を始める前に落としているので、切替元は動いたまま。
        #expect(readLines(stopLog).isEmpty)

        _ = try await coordinator.stop(source)
    }

    @Test("Docker 種別はヘルスチェック未実装として起動前に失敗させる")
    func dockerKindIsRejectedBeforeStart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = makeService(
            name: "Docker",
            kind: .docker,
            ports: [PortSpec(port: 5432, isPrimary: true)],
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 0.1; done"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [docker])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }
        if let failure {
            guard case .unsupportedConfiguration = failure.reason else {
                Issue.record("未対応設定として扱われなかった: \(failure.reason)")
                return
            }
        }
        #expect(await registry.isRunning(serviceID: docker.id) == false)
    }

    @Test("一部停止のまま明示的に停止したら、停止中になる")
    func explicitStopClearsEarlierStartFailures() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let stable = makeOrderedService(
            name: "Stable",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let optional = makeFailingService(
            name: "Optional",
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [stable, optional])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let started = try await coordinator.start(project)
        #expect(started.facts.target?.phase == .degraded(stoppedServices: ["Optional"]))

        // 止めたのに「一部停止」「失敗」が残ると、稼働中の一種として扱われ続ける。
        let stopped = try await coordinator.stop(project)
        #expect(stopped.facts.source?.phase == .stopped)
        #expect(await coordinator.projectFact(project).phase == .stopped)
        #expect(await coordinator.servicePhase(optional, in: project) == .stopped)
    }

    @Test("全サービスが continue でも、停止後は稼働中扱いにしない")
    func explicitStopAfterAllContinueFailuresIsNotActive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeFailingService(
            name: "First",
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let second = makeFailingService(
            name: "Second",
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [first, second])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let started = try await coordinator.start(project)
        #expect(started.degradedServices == ["First", "Second"])

        let stopped = try await coordinator.stop(project)
        let phase = try #require(stopped.facts.source?.phase)
        #expect(phase == .stopped)
        // ここが true のままだと、次のプロジェクトと同時に稼働中側へ残る。
        #expect(phase.isActive == false)
    }

    @Test("稼働開始後の異常終了をプロジェクトの状態へ反映する")
    func exitAfterHealthyIsReflectedInProjectPhase() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let marker = directory.appendingPathComponent("gone.marker")
        // ヘルスチェックを通過してから落ちる、失敗を許容するサービス。
        let optional = makeService(
            name: "Optional",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.5; echo gone > \"\(marker.path)\"; exit 1"],
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let stable = makeOrderedService(
            name: "Stable",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [optional, stable])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)
        #expect(outcome.facts.target?.phase == .running)

        #expect(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
        // 稼働後に落ちたサービスは、プロジェクトの状態にも出る。
        #expect(await waitUntil {
            await coordinator.projectFact(project).phase
                == .degraded(stoppedServices: ["Optional"])
        })

        _ = try await coordinator.stop(project)
    }

    @Test("親が終了して孫が残った場合は残存として扱い、停止の導線を残す")
    func survivingGrandchildIsReportedAsResidual() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ヘルスチェックを通過したあとに親だけが終了し、孫がグループに残る。
        let detached = makeService(
            name: "Detached",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "sleep 120 & sleep 1; exit 0"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [detached])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        _ = try await coordinator.start(project)
        // 親が終了するまで待つ。孫は残り続ける。
        #expect(await waitUntil { await registry.isRunning(serviceID: detached.id) == false })
        let processGroupID = try #require(
            await registry.occupiedProcessGroup(serviceID: detached.id)
        )
        defer { kill(-processGroupID, SIGKILL) }

        // 資源を握っている間は「失敗」でも「停止中」でもなく「残存あり」。
        // ここを失敗のままにすると、停止ボタンが出ず画面から復旧できない。
        #expect(await coordinator.servicePhase(detached, in: project) == .residual)
        let phase = await coordinator.projectFact(project).phase
        #expect(phase == .residual)
        #expect(phase.isActive)

        // 残存として扱われているので、停止の経路へ入れる。
        _ = try await coordinator.stop(project)
        #expect(await registry.occupiedProcessGroup(serviceID: detached.id) == nil)
        #expect(await coordinator.projectFact(project).phase == .stopped)
    }

    @Test("通常終了で止まらないサービスを、確認のうえ強制終了できる")
    func forceStopsServiceThatIgnoresSigterm() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // SIGTERM を無視し続ける固定コマンド。trap を仕掛け終えてから判定する。
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
        let project = makeProject(directory: directory, services: [stubborn])
        let (registry, coordinator) = makeStack(
            logDirectory: directory,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .milliseconds(800),
                healthTimeout: .seconds(5),
                healthObservationWindow: .milliseconds(200),
                healthPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        _ = try await coordinator.start(project)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: readyFile.path) })

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.stop(project)
        }

        // 失敗理由から強制終了の対象を特定できないと、画面から復旧できない。
        let details: [StopFailureDetail]
        if let failure, case let .stopFailed(services) = failure.reason {
            details = services
        } else {
            Issue.record("停止失敗として扱われなかった: \(String(describing: failure?.reason))")
            return
        }
        #expect(details.map(\.serviceID) == [stubborn.id])
        #expect(details.first?.processGroupID != nil)

        let outcomes = try await coordinator.forceStop(
            serviceIDs: details.map(\.serviceID),
            in: project
        )
        #expect(outcomes[stubborn.id]?.isStopped == true)
        #expect(await registry.occupiedProcessGroup(serviceID: stubborn.id) == nil)
        #expect(await coordinator.projectFact(project).phase == .stopped)
    }

    @Test("強制終了で資源が解放されたら、同じプロジェクトの過去の失敗も残さない")
    func forceStopClearsProjectWideFailureState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

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
            workingDirectory: directory,
            failurePolicy: .continue
        )
        // 先に落ちて「一部停止」を作るサービス。
        let optional = makeFailingService(
            name: "Optional",
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [stubborn, optional])
        let (registry, coordinator) = makeStack(
            logDirectory: directory,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .milliseconds(800),
                healthTimeout: .seconds(5),
                healthObservationWindow: .milliseconds(200),
                healthPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        let started = try await coordinator.start(project)
        #expect(started.degradedServices == ["Optional"])
        #expect(await waitUntil { FileManager.default.fileExists(atPath: readyFile.path) })

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.stop(project)
        }
        guard let failure, case let .stopFailed(details) = failure.reason else {
            Issue.record("停止失敗として扱われなかった")
            return
        }

        _ = try await coordinator.forceStop(serviceIDs: details.map(\.serviceID), in: project)

        // 強制終了した側だけでなく、先に落ちていた側の失敗も残さない。
        #expect(await registry.occupiedProcessGroup(serviceID: stubborn.id) == nil)
        #expect(await coordinator.servicePhase(optional, in: project) == .stopped)
        #expect(await coordinator.projectFact(project).phase == .stopped)
    }

    @Test("短い観測窓でも、起動直後に終了したサービスを稼働中にしない")
    func shortLivedServiceIsNeverHealthy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 終了通知の配送が遅れても、観測窓が短いだけで healthy にしてはいけない。
        // 同じ条件を繰り返し、負荷の揺らぎで結果が変わらないことを確かめる。
        for attempt in 1...5 {
            let broken = makeFailingService(
                name: "Broken\(attempt)",
                workingDirectory: directory,
                failurePolicy: .block
            )
            let project = makeProject(
                name: "Bell\(attempt)",
                directory: directory,
                services: [broken]
            )
            let (registry, coordinator) = makeStack(
                logDirectory: directory,
                options: SwitchCoordinator.Options(
                    releaseTimeout: .seconds(3),
                    stopGrace: .seconds(2),
                    healthTimeout: .seconds(2),
                    // 報告された条件と同じ観測窓。伸ばして隠さない。
                    healthObservationWindow: .milliseconds(200),
                    healthPollInterval: .milliseconds(10),
                    gatePollInterval: .milliseconds(10)
                )
            )

            await #expect(throws: SwitchFailure.self) {
                _ = try await coordinator.start(project)
            }
            #expect(await registry.isRunning(serviceID: broken.id) == false)
            let phase = await coordinator.servicePhase(broken, in: project)
            #expect(phase != .healthy, "\(attempt) 回目で短命プロセスを稼働中と判定した")
        }
    }

    @Test("短命な continue サービスが複数あっても、すべて一部停止として数える")
    func multipleShortLivedContinueServicesAreAllDegraded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for attempt in 1...5 {
            let first = makeFailingService(
                name: "First",
                workingDirectory: directory,
                failurePolicy: .continue
            )
            let second = makeFailingService(
                name: "Second",
                workingDirectory: directory,
                failurePolicy: .continue
            )
            let project = makeProject(
                name: "Bell\(attempt)",
                directory: directory,
                services: [first, second]
            )
            let (_, coordinator) = makeStack(
                logDirectory: directory,
                options: SwitchCoordinator.Options(
                    releaseTimeout: .seconds(3),
                    stopGrace: .seconds(2),
                    healthTimeout: .seconds(2),
                    healthObservationWindow: .milliseconds(200),
                    healthPollInterval: .milliseconds(10),
                    gatePollInterval: .milliseconds(10)
                )
            )

            let outcome = try await coordinator.start(project)
            #expect(
                outcome.degradedServices == ["First", "Second"],
                "\(attempt) 回目で一部停止の内訳がずれた: \(outcome.degradedServices)"
            )
        }
    }

    @Test("停止操作なしの終了を「停止中」で塗りつぶさない")
    func unrequestedExitIsNotReportedAsStopped() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let marker = directory.appendingPathComponent("gone.marker")
        // ヘルスチェックを通過したあとに、自分から終了するサービス。
        let selfExiting = makeService(
            name: "SelfExit",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.5; echo gone > \"\(marker.path)\"; exit 0"],
            workingDirectory: directory
        )
        let stable = makeOrderedService(
            name: "Stable",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [selfExiting, stable])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)
        // 起動時点ではまだ生きているので稼働中。
        #expect(outcome.facts.target?.phase == .running)

        #expect(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
        #expect(await waitUntil {
            await coordinator.servicePhase(selfExiting, in: project) != .healthy
        })

        // 終了コード 0 でも、頼んでいない終了は成功ではない。
        let phase = await coordinator.servicePhase(selfExiting, in: project)
        guard case let .failed(reason) = phase else {
            Issue.record("停止操作なしの終了が失敗として扱われなかった: \(phase)")
            return
        }
        #expect(reason.contains("停止操作なし"))

        _ = try await coordinator.stop(project)
    }

    @Test("ポートを実測できない場合は、空いているとみなさず起動しない")
    func portObservationFailureStopsTheSwitch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let world = FakePortWorld()
        await world.fail(with: PortInspectorError.unparsableOutput(line: "n???"))

        let service = makeOrderedService(
            name: "Web",
            ports: [PortSpec(port: 3700, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [service])
        let (_, coordinator) = makeStack(logDirectory: directory, world: world)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }
        if let failure {
            guard case .portObservationFailed = failure.reason else {
                Issue.record("実測失敗として扱われなかった: \(failure.reason)")
                return
            }
        }
        #expect(readLines(startLog).isEmpty)
    }

    @Test("切替元の最新ポート観測に失敗したら停止も切替先起動も行わない")
    func sourcePortObservationFailureAbortsBeforeStopping() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceStartLog = directory.appendingPathComponent("source-start.log")
        let sourceStopLog = directory.appendingPathComponent("source-stop.log")
        let targetStartLog = directory.appendingPathComponent("target-start.log")
        let targetStopLog = directory.appendingPathComponent("target-stop.log")
        let probe = RuntimePortProbeControl()
        let signals = SignalRecorder()
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { try await probe.probe($0) },
            signalSender: { processGroupID, signal in
                _ = signals.send(processGroupID, signal)
                return kill(-processGroupID, signal)
            }
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .seconds(2),
                healthTimeout: .seconds(2),
                healthObservationWindow: .milliseconds(100),
                healthPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        let sourceService = makeOrderedService(
            name: "Source",
            workingDirectory: directory,
            startLog: sourceStartLog,
            stopLog: sourceStopLog
        )
        let targetService = makeOrderedService(
            name: "Target",
            workingDirectory: directory,
            startLog: targetStartLog,
            stopLog: targetStopLog
        )
        let source = makeProject(name: "Source", directory: directory, services: [sourceService])
        let target = makeProject(name: "Target", directory: directory, services: [targetService])

        _ = try await coordinator.start(source)
        defer { Task { _ = try? await registry.forceStop(service: sourceService) } }
        #expect(await registry.isRunning(serviceID: sourceService.id))
        await probe.fail(with: .unparsableOutput(line: "broken"))

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.switchProject(from: source, to: target)
        }
        if let failure {
            guard case .portObservationFailed = failure.reason else {
                Issue.record("ポート観測失敗として扱われなかった: \(failure.reason)")
                return
            }
        }
        #expect(signals.count == 0)
        #expect(await registry.isRunning(serviceID: sourceService.id))
        #expect(readLines(sourceStopLog).isEmpty)
        #expect(readLines(targetStartLog).isEmpty)
        #expect(await registry.isRunning(serviceID: targetService.id) == false)

        _ = try await registry.forceStop(service: sourceService)
    }
}

/// 進行状態の記録。順序の検証にだけ使う。
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SwitchState] = []

    func append(_ state: SwitchState) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(state)
    }

    var states: [SwitchState] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
