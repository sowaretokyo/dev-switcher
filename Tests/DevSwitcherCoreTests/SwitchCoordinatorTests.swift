import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("プロジェクトの起動・停止・切替")
struct SwitchCoordinatorTests {
    /// ポート実測を差し替えたスタック。
    /// 実プロセスの起動・停止・順序は本物のまま検証する。
    ///
    /// `portProbe` は「そのサービスが実際に listen していた」という観測を差し替える。
    /// 停止元の解放確認（ゲート）の対象は、設定値ではなくこの実測から決まる。
    private func makeStack(
        logDirectory: URL,
        world: FakePortWorld? = nil,
        portProbe: ServiceSupervisor.PortProbe? = nil,
        options: SwitchCoordinator.Options = SwitchCoordinator.Options(
            releaseTimeout: .seconds(3),
            stopGrace: .seconds(5),
            startupObservationWindow: .milliseconds(200),
            startupPollInterval: .milliseconds(50),
            gatePollInterval: .milliseconds(50)
        )
    ) -> (RuntimeRegistry, SwitchCoordinator) {
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: logDirectory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: portProbe ?? { processGroupID in
                try await PortInspector.listeningPorts(processGroupID: processGroupID)
            }
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
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

        // 切替先の設定ポートを調べていないことを、問い合わせたポート集合から確かめる。
        let probedSets = await world.probedPortSets
        #expect(probedSets.allSatisfy { $0 == [sourcePort] })

        _ = try? await coordinator.stop(source)
    }

    @Test("設定ポートが外部プロセスに使われていても、起動前に競合として止めない")
    func configuredPortInUseDoesNotBlockStart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let world = FakePortWorld()
        // 設定ポートを外部プロセスが握っている状況。
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

        let outcome = try await coordinator.start(project)

        // 設定ポートの空き確認をしないので、両方とも起動を試みる。
        #expect(readLines(startLog) == ["First", "Second"])
        #expect(outcome.facts.target?.phase == .running)
        // 起動前にポートを1つも調べていない。
        #expect(await world.probedPortSets.isEmpty)

        _ = try await coordinator.stop(project)
    }

    @Test("設定ポートを持つサービスでも、そのポートへ接続しない")
    func doesNotConnectToConfiguredPort() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 設定ポートを本物のリスナーが握っている状況。接続されたら数が増える。
        let listener = try LocalTCPServer(behavior: .http(status: 200))
        defer { listener.stop() }

        let web = makeService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: listener.port, isPrimary: true)],
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 0.1; done"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [web])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        // 設定ポートへ GET していたら、別プロセスの 200 を自分の応答と誤認していた。
        #expect(listener.acceptedConnectionCount == 0)
        #expect(outcome.facts.target?.phase == .running)
        #expect(await coordinator.servicePhase(web, in: project) == .healthy)

        _ = try await coordinator.stop(project)
        #expect(listener.acceptedConnectionCount == 0)
    }

    @Test("ポート未入力の Web サービスをプロセスの生存だけで起動できる")
    func webServiceWithoutPortStarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let web = makeOrderedService(
            name: "Web",
            kind: .web,
            ports: [],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [web])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(outcome.facts.target?.phase == .running)
        #expect(await coordinator.servicePhase(web, in: project) == .healthy)
        #expect(await registry.isRunning(serviceID: web.id))

        _ = try await coordinator.stop(project)
    }

    @Test("ポート未入力の Inngest サービスをプロセスの生存だけで起動できる")
    func inngestServiceWithoutPortStarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let inngest = makeOrderedService(
            name: "Inngest",
            kind: .inngest,
            ports: [],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [inngest])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(outcome.facts.target?.phase == .running)
        #expect(await coordinator.servicePhase(inngest, in: project) == .healthy)
        #expect(await registry.isRunning(serviceID: inngest.id))

        _ = try await coordinator.stop(project)
    }

    @Test("同じ設定ポートの2サービスも、設定順に両方とも起動を試みる")
    func servicesSharingAPortAreBothStartedInOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        // 同じポートを設定していても、後続をスキップしない。
        // どちらが取るかは OS が決める（先に bind したプロセスが取る）。
        let first = makeOrderedService(
            name: "First",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let second = makeOrderedService(
            name: "Second",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [first, second])
        let (_, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(readLines(startLog) == ["First", "Second"])
        #expect(outcome.degradedServices.isEmpty)
        #expect(outcome.facts.target?.phase == .running)

        _ = try await coordinator.stop(project)
    }

    @Test("同じ設定ポートの2番目が終了しても、continue なら1番目を残して一部停止にする")
    func secondServiceOnSamePortExitingIsDegradedWhenContinue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let first = makeOrderedService(
            name: "First",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        // ポートを取れずに終了した後続サービスは、通常の起動失敗として扱う。
        let second = makeFailingService(
            name: "Second",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let project = makeProject(directory: directory, services: [first, second])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        let outcome = try await coordinator.start(project)

        #expect(outcome.degradedServices == ["Second"])
        #expect(outcome.facts.target?.phase == .degraded(stoppedServices: ["Second"]))
        #expect(await registry.isRunning(serviceID: first.id))

        _ = try await coordinator.stop(project)
    }

    @Test("同じ設定ポートの2番目が終了したら、block では1番目を補償停止する")
    func secondServiceOnSamePortExitingRollsBackWhenBlock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let first = makeOrderedService(
            name: "First",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let second = makeFailingService(
            name: "Second",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory,
            failurePolicy: .block
        )
        let project = makeProject(directory: directory, services: [first, second])
        let (registry, coordinator) = makeStack(logDirectory: directory)

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }
        if let failure {
            guard case let .startFailed(service, _) = failure.reason else {
                Issue.record("起動失敗として扱われなかった: \(failure.reason)")
                return
            }
            #expect(service == "Second")
        }

        // 2番目を起動しようとはした。落ちたので1番目を巻き戻す。
        #expect(readLines(startLog) == ["First"])
        #expect(readLines(stopLog) == ["First"])
        #expect(await registry.isRunning(serviceID: first.id) == false)
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

        // 切替元が 3300 を listen していたことにする。ゲートの対象は実測から決まるので、
        // これがないと解放確認そのものが起きない。
        let (registry, coordinator) = makeStack(
            logDirectory: directory,
            world: world,
            portProbe: { processGroupID in
                [ObservedPort(port: 3300, pid: processGroupID, address: "127.0.0.1")]
            }
        )
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

        let service = makeOrderedService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: 3400, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [service])

        // 起動確認の観測中（＝起動フェーズ内）で中止が拒否されることを見る。
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .seconds(5),
                startupObservationWindow: .seconds(2),
                startupPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        let recorder = ProgressRecorder()
        let startTask = Task {
            try await coordinator.start(project, progress: { recorder.append($0) })
        }
        // 起動フェーズへ入ったことを進捗から確かめてから中止する。
        #expect(await waitUntil {
            recorder.states.contains { $0.hasEnteredStartPhase }
        })
        #expect(await coordinator.cancel() == false)

        _ = try await startTask.value
        #expect(await waitUntil { readLines(startLog) == ["Web"] })

        _ = try await coordinator.stop(project)
    }

    @Test("切替元の実測ポートが解放されていれば、停止・解放確認・起動の順に進む")
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
        // 切替元が 3500 を listen していたことにする。解放確認の対象は実測から決まる。
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            world: world,
            portProbe: { processGroupID in
                [ObservedPort(port: 3500, pid: processGroupID, address: "127.0.0.1")]
            }
        )

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
        let startIndex = states.firstIndex { if case .starting = $0 { return true } else { return false } }

        #expect(stopIndex != nil)
        #expect(releaseIndex != nil)
        #expect(startIndex != nil)
        if let stopIndex, let releaseIndex, let startIndex {
            #expect(stopIndex < releaseIndex)
            #expect(releaseIndex < startIndex)
        }

        // 解放確認の対象は切替元の実測ポートだけ。切替先の設定ポート 3501 は調べない。
        #expect(await world.probedPortSets.allSatisfy { $0 == [3500] })
        #expect(await world.probedPortSets.isEmpty == false)

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

        let service = makeOrderedService(
            name: "Web",
            kind: .web,
            ports: [PortSpec(port: 3600, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = makeProject(directory: directory, services: [service])
        // 起動確認の観測窓を長めに取り、1件目が実行中の間に2件目を試す。
        let (_, coordinator) = makeStack(
            logDirectory: directory,
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(3),
                stopGrace: .seconds(5),
                startupObservationWindow: .seconds(2),
                startupPollInterval: .milliseconds(50),
                gatePollInterval: .milliseconds(50)
            )
        )

        let recorder = ProgressRecorder()
        let first = Task {
            try await coordinator.start(project, progress: { recorder.append($0) })
        }
        #expect(await waitUntil {
            recorder.states.contains { if case .observingStartup = $0 { return true } else { return false } }
        })

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(project)
        }
        if let failure {
            #expect(failure.reason == .operationInProgress)
        }

        _ = try await first.value
        _ = try await coordinator.stop(project)
    }

    @Test("状態確認方法のないカスタム終了コマンドは、停止を始める前に失敗させる")
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

        // Supabase以外の任意managed commandには、まだ状態確認方法が無い。
        let managed = makeService(
            name: "Custom managed command",
            kind: .other,
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

    @Test("Docker 種別は Post-MVP として起動前に明示的に拒否する")
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

        // ポートを外しても拒否は変わらない。ポートの有無が理由ではない。
        let withoutPort = makeService(
            name: "Docker",
            kind: .docker,
            ports: [],
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 0.1; done"],
            workingDirectory: directory
        )
        let portless = makeProject(
            name: "Penta",
            directory: directory,
            services: [withoutPort]
        )
        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.start(portless)
        }
        #expect(await registry.isRunning(serviceID: withoutPort.id) == false)
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

        let exitTrigger = directory.appendingPathComponent("exit.trigger")
        // 全サービスの起動成功を確認してから、合図で異常終了させる。
        let optional = makeService(
            name: "Optional",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                while [ ! -e "$1" ]; do
                    kill -0 "$3" 2>/dev/null && [ -d "$2" ] || exit 2
                    sleep 0.02
                done
                exit 1
                """,
                "optional-exit",
                exitTrigger.path,
                directory.path,
                String(getpid()),
            ],
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

        try Data().write(to: exitTrigger, options: .atomic)
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

        // 起動確認を通過したあとに親だけが終了し、孫がグループに残る。
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
                startupObservationWindow: .milliseconds(200),
                startupPollInterval: .milliseconds(50),
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
                startupObservationWindow: .milliseconds(200),
                startupPollInterval: .milliseconds(50),
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
                    // 報告された条件と同じ観測窓。伸ばして隠さない。
                    startupObservationWindow: .milliseconds(200),
                    startupPollInterval: .milliseconds(10),
                    gatePollInterval: .milliseconds(10)
                )
            )

            await #expect(throws: SwitchFailure.self) {
                _ = try await coordinator.start(project)
            }
            #expect(await registry.isRunning(serviceID: broken.id) == false)
            let phase = await coordinator.servicePhase(broken, in: project)
                #expect(phase != .healthy, "\(attempt) 回目で短命プロセスを起動済みと判定した")
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
                    startupObservationWindow: .milliseconds(200),
                    startupPollInterval: .milliseconds(10),
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

        let exitTrigger = directory.appendingPathComponent("exit.trigger")
        // 全サービスの起動成功を確認してから、合図で自発終了させる。
        let selfExiting = makeService(
            name: "SelfExit",
            kind: .worker,
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                while [ ! -e "$1" ]; do
                    kill -0 "$3" 2>/dev/null && [ -d "$2" ] || exit 2
                    sleep 0.02
                done
                exit 0
                """,
                "self-exit",
                exitTrigger.path,
                directory.path,
                String(getpid()),
            ],
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

        try Data().write(to: exitTrigger, options: .atomic)
        #expect(await waitUntil {
            await coordinator.servicePhase(selfExiting, in: project) != .healthy
        })

        // 終了コード 0 でも、頼んでいない終了は成功ではない。
        let phase = await coordinator.servicePhase(selfExiting, in: project)
        if case let .failed(reason) = phase {
            #expect(reason.contains("停止操作なし"))
        } else {
            Issue.record("停止操作なしの終了が失敗として扱われなかった: \(phase)")
        }

        // 検証失敗時も残りのサービスを止める。明示停止後には古い終了結果を再表示しない。
        _ = try await coordinator.stop(project)
        #expect(await coordinator.servicePhase(selfExiting, in: project) == .stopped)
    }

    @Test("停止元のポート解放を実測できない場合は、解放されたとみなさず切替先を起動しない")
    func portObservationFailureStopsTheSwitch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")

        let world = FakePortWorld()
        await world.fail(with: PortInspectorError.unparsableOutput(line: "n???"))

        let sourceService = makeOrderedService(
            name: "Source",
            ports: [PortSpec(port: 3700, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let source = makeProject(name: "Bell", directory: directory, services: [sourceService])
        let targetService = makeOrderedService(
            name: "Target",
            ports: [PortSpec(port: 3701, isPrimary: true)],
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let target = makeProject(name: "Penta", directory: directory, services: [targetService])

        let (registry, coordinator) = makeStack(
            logDirectory: directory,
            world: world,
            portProbe: { processGroupID in
                [ObservedPort(port: 3700, pid: processGroupID, address: "127.0.0.1")]
            }
        )

        _ = try await coordinator.start(source)
        #expect(await waitUntil { readLines(startLog) == ["Source"] })

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.switchProject(from: source, to: target)
        }
        if let failure {
            guard case .portObservationFailed = failure.reason else {
                Issue.record("実測失敗として扱われなかった: \(failure.reason)")
                return
            }
        }
        #expect(readLines(startLog) == ["Source"])
        #expect(await registry.isRunning(serviceID: targetService.id) == false)
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
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
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

@Suite("プロセス単体の再起動")
struct ServiceRestartTests {
    @Test("対象だけを停止して再起動し、同じプロジェクトの他プロセスは残す")
    func restartsOnlyTheSelectedService() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let world = ControlledProcessWorld()
        let registry = RuntimeRegistry(
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
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(1),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        let web = makeService(
            name: "Web",
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let worker = makeService(
            name: "Worker",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [web, worker])

        let events = ServiceEventRecorder()
        _ = try await coordinator.start(
            project,
            events: { events.record(serviceID: $0, event: $1) }
        )
        defer { Task { _ = try? await coordinator.stop(project) } }
        let originalWeb = try #require(
            await registry.runtimeSnapshot(serviceID: web.id)?.processID
        )
        let originalWorker = try #require(
            await registry.runtimeSnapshot(serviceID: worker.id)?.processID
        )
        #expect(events.logSessionServiceIDs == [web.id, worker.id])
        events.clear()
        world.clearSignals()

        let fact = try await coordinator.restart(
            web,
            in: project,
            events: { events.record(serviceID: $0, event: $1) }
        )

        let restartedWeb = try #require(
            await registry.runtimeSnapshot(serviceID: web.id)?.processID
        )
        let unchangedWorker = try #require(
            await registry.runtimeSnapshot(serviceID: worker.id)?.processID
        )
        #expect(restartedWeb != originalWeb)
        #expect(unchangedWorker == originalWorker)
        #expect(await registry.isRunning(serviceID: worker.id))
        #expect(fact.phase == .running)
        #expect(world.signals == [
            ControlledProcessWorld.SentSignal(
                processGroupID: originalWeb,
                signal: SIGTERM
            ),
        ])
        #expect(events.logSessionServiceIDs == [web.id])

        _ = try await coordinator.stop(project)
    }

    @Test("対象の再起動に失敗しても、同じプロジェクトの他プロセスは停止しない")
    func restartFailureKeepsSiblingRunning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let world = ControlledProcessWorld()
        let registry = RuntimeRegistry(
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
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(1),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        let web = makeService(
            name: "Web",
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let worker = makeService(
            name: "Worker",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let runningProject = makeProject(directory: directory, services: [web, worker])

        _ = try await coordinator.start(runningProject)
        defer { Task { _ = try? await coordinator.stop(runningProject) } }
        let originalWeb = try #require(
            await registry.runtimeSnapshot(serviceID: web.id)?.processID
        )
        let originalWorker = try #require(
            await registry.runtimeSnapshot(serviceID: worker.id)?.processID
        )
        var failingWeb = web
        failingWeb.start.executable = "/path/that/does/not/exist"
        var currentProject = runningProject
        currentProject.services = [failingWeb, worker]
        world.clearSignals()

        await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.restart(failingWeb, in: currentProject)
        }

        #expect(await registry.occupiedProcessGroup(serviceID: web.id) == nil)
        #expect(await registry.runtimeSnapshot(serviceID: worker.id)?.processID == originalWorker)
        #expect(await registry.isRunning(serviceID: worker.id))
        #expect(world.signals == [
            ControlledProcessWorld.SentSignal(
                processGroupID: originalWeb,
                signal: SIGTERM
            ),
        ])

        _ = try await coordinator.stop(currentProject)
    }

    @Test("ポート解放失敗後も、対象だけの再起動を再試行できる")
    func retriesSelectedServiceAfterPortReleaseFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let world = ControlledProcessWorld()
        let ports = FakePortWorld()
        await ports.occupy(port: 3000, pid: 9000, command: "external", loginName: "other-user")
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            identityProbe: { world.identity(pid: $0, workingDirectory: $1) },
            portProbe: { processGroupID in
                [ObservedPort(port: 3000, pid: processGroupID, address: "127.0.0.1")]
            },
            signalSender: { world.send(processGroupID: $0, signal: $1) },
            groupStateProbe: { world.groupState(processGroupID: $0) },
            startAbstimeProbe: { world.startObservation(pid: $0) },
            bootSessionProbe: { "TEST-BOOT-SESSION" }
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { try await ports.probe($0) },
            options: SwitchCoordinator.Options(
                releaseTimeout: .milliseconds(20),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(10)
            ),
            currentUserName: "test-user"
        )
        let web = makeService(
            name: "Web",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let worker = makeService(
            name: "Worker",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [web, worker])

        _ = try await coordinator.start(project)
        defer { Task { _ = try? await coordinator.stop(project) } }
        let originalWeb = try #require(
            await registry.runtimeSnapshot(serviceID: web.id)?.processID
        )
        let originalWorker = try #require(
            await registry.runtimeSnapshot(serviceID: worker.id)?.processID
        )
        world.clearSignals()

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.restart(web, in: project)
        }
        if let failure {
            guard case .portsNotReleased = failure.reason else {
                Issue.record("ポート解放失敗ではない: \(failure.reason)")
                return
            }
        }
        guard case .failed = await coordinator.servicePhase(web, in: project) else {
            Issue.record("再起動失敗後の対象が失敗状態ではない")
            return
        }
        #expect(await registry.occupiedProcessGroup(serviceID: web.id) == nil)
        #expect(await registry.runtimeSnapshot(serviceID: worker.id)?.processID == originalWorker)
        #expect(world.signals == [
            ControlledProcessWorld.SentSignal(
                processGroupID: originalWeb,
                signal: SIGTERM
            ),
        ])

        await ports.release(port: 3000)
        let fact = try await coordinator.restart(web, in: project)

        let restartedWeb = try #require(
            await registry.runtimeSnapshot(serviceID: web.id)?.processID
        )
        #expect(restartedWeb != originalWeb)
        #expect(await registry.runtimeSnapshot(serviceID: worker.id)?.processID == originalWorker)
        #expect(fact.phase == .running)
        #expect(world.signals.count == 1)

        _ = try await coordinator.stop(project)
    }

    @Test("起動対象外のサービスはCore APIからも再起動できない")
    func disabledServiceCannotBeRestartedThroughCoreAPI() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let world = ControlledProcessWorld()
        let registry = RuntimeRegistry(
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
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(1),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(100),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        let web = makeService(
            name: "Web",
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let worker = makeService(
            name: "Worker",
            kind: .worker,
            ports: [],
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: directory
        )
        let project = makeProject(
            directory: directory,
            services: [web, worker],
            enabledNow: [web.id: false, worker.id: true]
        )

        _ = try await coordinator.start(project)
        defer { Task { _ = try? await coordinator.stop(project) } }
        let workerPID = try #require(
            await registry.runtimeSnapshot(serviceID: worker.id)?.processID
        )
        world.clearSignals()

        let failure = await #expect(throws: SwitchFailure.self) {
            _ = try await coordinator.restart(web, in: project)
        }

        if let failure {
            guard case let .unsupportedConfiguration(reason) = failure.reason else {
                Issue.record("設定エラーではない: \(failure.reason)")
                return
            }
            #expect(reason.contains("起動対象から外れています"))
        }
        #expect(await registry.occupiedProcessGroup(serviceID: web.id) == nil)
        #expect(await registry.runtimeSnapshot(serviceID: worker.id)?.processID == workerPID)
        #expect(world.signals.isEmpty)

        _ = try await coordinator.stop(project)
    }
}

private final class ServiceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLogSessionServiceIDs: [UUID] = []

    func record(serviceID: UUID, event: ServiceSupervisor.Event) {
        guard case .logSessionStarted = event else { return }
        lock.lock()
        recordedLogSessionServiceIDs.append(serviceID)
        lock.unlock()
    }

    var logSessionServiceIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLogSessionServiceIDs
    }

    func clear() {
        lock.lock()
        recordedLogSessionServiceIDs.removeAll()
        lock.unlock()
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
