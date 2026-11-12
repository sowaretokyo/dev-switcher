import Foundation
import Testing
@testable import DevSwitcherCore

/// `SwitchCoordinator`の種類共通の確認フローを、`FakeManagedStackDriver`だけで確かめる。
/// 実Docker・実Supabaseには触れない。設定ファイル（`config.toml`）は一時ディレクトリに書く。
@Suite("管理対象スタックの確認フロー（種類共通）")
struct ManagedStackCoordinatorTests {
    // MARK: - 準備

    private func makeCoordinator(
        driver: any ManagedStackDriver,
        logDirectory: URL
    ) -> (RuntimeRegistry, SwitchCoordinator) {
        let registry = RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: logDirectory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in [] },
            stackDrivers: [.supabase: driver]
        )
        let coordinator = SwitchCoordinator(
            registry: registry,
            portHolderProbe: { _ in [] },
            options: SwitchCoordinator.Options(
                releaseTimeout: .seconds(2),
                stopGrace: .seconds(2),
                startupObservationWindow: .milliseconds(150),
                startupPollInterval: .milliseconds(20),
                gatePollInterval: .milliseconds(20)
            ),
            currentUserName: "test-user"
        )
        return (registry, coordinator)
    }

    private func makeStackProject(
        name: String = "Bell",
        stackValue: String = "bell",
        directory: URL,
        stackFailurePolicy: FailurePolicy = .block,
        extraServices: [LaunchUnit] = []
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: stackValue, in: directory)
        return makeProject(
            name: name,
            directory: directory,
            services: [
                makeSupabaseService(workingDirectory: directory, failurePolicy: stackFailurePolicy),
            ] + extraServices
        )
    }

    private func switchFailure(
        _ operation: () async throws -> SwitchOutcome
    ) async throws -> SwitchFailure {
        do {
            _ = try await operation()
        } catch {
            return try #require(error as? SwitchFailure)
        }
        Issue.record("失敗するはずの操作が成功した")
        throw CancellationError()
    }

    private func confirmationPlan(_ failure: SwitchFailure) throws -> ManagedStackConfirmationPlan {
        guard case let .managedStackConfirmationRequired(plan) = failure.reason else {
            Issue.record("確認要求ではない失敗: \(failure.reason)")
            throw failure
        }
        return plan
    }

    /// 観測を除いた、状態を変える呼び出し（start / stop）だけを並べる。
    private func mutations(_ calls: [FakeManagedStackDriver.Call]) -> [String] {
        calls.compactMap { call -> String? in
            switch call {
            case .observe:
                nil
            case let .start(identity, _):
                "start \(identity)"
            case let .stop(identity, context, _):
                "stop \(identity) using \(context)"
            }
        }
    }

    // MARK: - 確認が要る場合の中断

    @Test("別IDが稼働していれば、何も変更せずに対象行・停止行の順の確認 plan で中断する")
    func abortsWithConfirmationPlanBeforeAnyChange() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let driver = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("other"): .running]
        )
        let (registry, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)

        let failure = try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        }
        let plan = try confirmationPlan(failure)

        #expect(plan.environmentName == "Bell")
        #expect(plan.entries.map(\.identity) == [try makeSupabaseIdentity("bell"), try makeSupabaseIdentity("other")])
        #expect(plan.entries.map(\.action) == [.start, .stop])
        #expect(plan.entries.map(\.stackID) == [service.id, nil])
        #expect(plan.requiresConfirmation)
        #expect(mutations(await driver.calls).isEmpty)
        #expect(await registry.managedRelationship(stackID: service.id) == nil)
    }

    @Test("承認すると、停止行を対象の設定で停止してから対象を起動する")
    func approvedPlanStopsWithTargetContextThenStarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let driver = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("other"): .running]
        )
        let (registry, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let plan = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })

        _ = try await coordinator.start(
            project,
            registeredProjects: [project],
            approval: plan.approval
        )

        #expect(mutations(await driver.calls) == ["stop other using bell", "start bell"])
        #expect(await registry.managedRelationship(stackID: service.id) == .launched)

        _ = try await coordinator.stop(project, registeredProjects: [project])
    }

    // MARK: - 承認後の不一致

    @Test("承認後に観測が変わっていたら、何も変更せず最新の plan で確認し直す")
    func reconfirmsWithLatestPlanWhenObservationChangedAfterApproval() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let driver = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("other"): .running]
        )
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })

        await driver.setState(try makeSupabaseIdentity("zeta"), .running)
        let latest = try confirmationPlan(try await switchFailure {
            try await coordinator.start(
                project,
                registeredProjects: [project],
                approval: approved.approval
            )
        })

        #expect(latest != approved)
        #expect(latest.entries.map(\.identity)
            == [try makeSupabaseIdentity("bell"), try makeSupabaseIdentity("other"), try makeSupabaseIdentity("zeta")])
        #expect(mutations(await driver.calls).isEmpty)
    }

    @Test("承認済みの停止の後に別IDが現れたら、起動せず最新の plan で確認し直す")
    func reconfirmsWhenNewStackAppearsAfterApprovedStops() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let base = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("other"): .running]
        )
        let driver = ScriptedStackDriver(base: base)
        await driver.appearOnStop(of: try makeSupabaseIdentity("other"), identity: try makeSupabaseIdentity("zeta"))
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })

        let latest = try confirmationPlan(try await switchFailure {
            try await coordinator.start(
                project,
                registeredProjects: [project],
                approval: approved.approval
            )
        })

        #expect(latest.entries.map(\.identity) == [try makeSupabaseIdentity("bell"), try makeSupabaseIdentity("zeta")])
        #expect(latest.entries.map(\.action) == [.start, .stop])
        // 承認済みの other は停止済み。対象は起動しない。
        #expect(mutations(await base.calls) == ["stop other using bell"])
    }

    @Test("停止行が無く引き継ぐだけの承認でも、引き継ぐ直前に notRunning なら引き継がず最新の plan で確認し直す")
    func reconfirmsWhenAdoptTargetStopsBeforeAdoption() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        let base = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("bell"): .running]
        )
        let driver = ScriptedStackDriver(base: base)
        let (registry, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })
        #expect(approved.entries.map(\.action) == [.adopt])
        #expect(approved.entries.map(\.state) == [.running])

        // 承認後の観測は、起動前の実測・確認時の照合・引き継ぐ直前の再観測の 3 回。
        // 3 回目の直前に対象が止まる。
        await driver.changeState(try makeSupabaseIdentity("bell"), to: nil, beforeObserveCall: 3)
        let latest = try confirmationPlan(try await switchFailure {
            try await coordinator.start(
                project,
                registeredProjects: [project],
                approval: approved.approval
            )
        })

        #expect(await driver.observeCalls == 3)
        #expect(await driver.appliedChangeAtObserveCall == 3)
        #expect(latest.entries.map(\.identity) == [try makeSupabaseIdentity("bell")])
        #expect(latest.entries.map(\.state) == [.notRunning])
        #expect(latest.entries.map(\.action) == [.start])
        #expect(mutations(await base.calls).isEmpty)
        #expect(await registry.managedRelationship(stackID: service.id) == nil)
    }

    // MARK: - unknown

    @Test("unknown の ID があれば、確認へ進まず何も変更しない")
    func unknownObservationChangesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let driver = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("other"): .unknown]
        )
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)

        let failure = try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        }

        #expect(
            failure.reason
                == .managedStackObservationFailed(
                    types: [.supabase],
                    details: ["other: 理由を取得できませんでした。"]
                )
        )
        #expect(mutations(await driver.calls).isEmpty)
    }

    @Test("観測全体が失敗したら、確認へ進まず何も変更しない")
    func observationFailureChangesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let driver = FakeManagedStackDriver(type: .supabase)
        await driver.failObservation("docker に接続できません")
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)

        let failure = try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        }

        #expect(
            failure.reason
                == .managedStackObservationFailed(types: [.supabase], details: ["docker に接続できません"])
        )
        #expect(mutations(await driver.calls).isEmpty)
    }

    // MARK: - 停止失敗

    @Test("承認済みの停止が途中で失敗したら、停止済み・未処理を残して中断し、再起動しない")
    func stopFailureKeepsStoppedAndRemaining() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try makeStackProject(directory: directory)
        let base = FakeManagedStackDriver(
            type: .supabase,
            states: [
                try makeSupabaseIdentity("alpha"): .running,
                try makeSupabaseIdentity("beta"): .running,
                try makeSupabaseIdentity("gamma"): .running,
            ]
        )
        let driver = ScriptedStackDriver(base: base)
        await driver.failStop(of: try makeSupabaseIdentity("beta"))
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })

        let failure = try await switchFailure {
            try await coordinator.start(
                project,
                registeredProjects: [project],
                approval: approved.approval
            )
        }

        guard case let .managedStackStopFailed(stopIdentity, _, stopped, remaining) = failure.reason else {
            Issue.record("停止失敗ではない: \(failure.reason)")
            return
        }
        #expect(stopIdentity == (try makeSupabaseIdentity("beta")))
        #expect(stopped == ["alpha"])
        #expect(remaining == ["gamma"])
        #expect(mutations(await base.calls) == ["stop alpha using bell"])
        #expect(await driver.failedStopAttempts == [try makeSupabaseIdentity("beta")])
    }

    // MARK: - 起動失敗後の占有

    @Test("起動失敗後に notRunning 以外なら、failurePolicy: continue でも中断し、自動停止しない")
    func startFailureLeavingStackOccupiedAborts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startLog = directory.appendingPathComponent("start.log")
        let stopLog = directory.appendingPathComponent("stop.log")
        let follower = makeOrderedService(
            name: "Web",
            workingDirectory: directory,
            startLog: startLog,
            stopLog: stopLog
        )
        let project = try makeStackProject(
            directory: directory,
            stackFailurePolicy: .continue,
            extraServices: [follower]
        )
        let service = try #require(project.launchUnits.first)
        let base = FakeManagedStackDriver(type: .supabase)
        let driver = ScriptedStackDriver(base: base)
        await driver.failStart(leaving: .degraded)
        let (registry, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)

        let failure = try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        }

        guard case let .startFailed(serviceName, _) = failure.reason else {
            Issue.record("起動失敗ではない: \(failure.reason)")
            return
        }
        #expect(serviceName == service.name)
        #expect(await registry.managedRelationship(stackID: service.id) == nil)
        #expect(mutations(await base.calls).isEmpty)
        #expect(readLines(startLog).isEmpty)
    }

    // MARK: - block 失敗

    @Test("後続の block 失敗でも、引き継いだスタックは巻き戻さず残存ありとして残す")
    func blockingFailureDoesNotRollBackAdoptedStack() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = makeFailingService(name: "Web", workingDirectory: directory, failurePolicy: .block)
        let project = try makeStackProject(directory: directory, extraServices: [failing])
        let service = try #require(project.launchUnits.first)
        let driver = FakeManagedStackDriver(
            type: .supabase,
            states: [try makeSupabaseIdentity("bell"): .running]
        )
        let (registry, coordinator) = makeCoordinator(driver: driver, logDirectory: directory)
        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.start(project, registeredProjects: [project])
        })
        #expect(approved.entries.map(\.action) == [.adopt])

        let failure = try await switchFailure {
            try await coordinator.start(
                project,
                registeredProjects: [project],
                approval: approved.approval
            )
        }

        guard case .startFailed = failure.reason else {
            Issue.record("起動失敗ではない: \(failure.reason)")
            return
        }
        #expect(mutations(await driver.calls).isEmpty)
        #expect(await registry.managedRelationship(stackID: service.id) == .adopted)
        #expect(await coordinator.servicePhase(service, in: project) == .residual)

        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(mutations(await driver.calls) == ["stop bell using bell"])
    }

    // MARK: - 切替元の管理下スタック

    @Test("切替元の管理下スタックは停止行に入らず、通常の停止処理で止まる")
    func switchSourceManagedStackIsNotAStopEntry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("bell", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("penta", isDirectory: true)
        for directory in [sourceDirectory, targetDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = try makeStackProject(directory: sourceDirectory)
        let target = try makeStackProject(name: "Penta", stackValue: "penta", directory: targetDirectory)
        let driver = FakeManagedStackDriver(type: .supabase)
        let (_, coordinator) = makeCoordinator(driver: driver, logDirectory: root)

        _ = try await coordinator.start(source, registeredProjects: [source, target])
        await driver.resetCalls()
        await driver.setState(try makeSupabaseIdentity("other"), .running)

        let approved = try confirmationPlan(try await switchFailure {
            try await coordinator.switchProject(
                from: source,
                to: target,
                registeredProjects: [source, target]
            )
        })
        #expect(approved.entries.map(\.identity) == [try makeSupabaseIdentity("penta"), try makeSupabaseIdentity("other")])
        #expect(approved.entries.map(\.action) == [.start, .stop])
        #expect(mutations(await driver.calls).isEmpty)

        _ = try await coordinator.switchProject(
            from: source,
            to: target,
            registeredProjects: [source, target],
            approval: approved.approval
        )

        #expect(mutations(await driver.calls)
            == ["stop bell using bell", "stop other using penta", "start penta"])

        _ = try await coordinator.stop(target, registeredProjects: [source, target])
    }
}

/// `FakeManagedStackDriver`へ委ね、停止・起動の失敗と、停止に伴う別スタックの出現を差し込む。
/// 失敗させた呼び出しは`base`へ渡さないため、`base.calls`には成功した呼び出しだけが残る。
private actor ScriptedStackDriver: ManagedStackDriver {
    struct InjectedFailure: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated let type: ManagedStackType
    let base: FakeManagedStackDriver
    private var failingStops: Set<ManagedStackIdentity> = []
    private var startFailureState: ManagedStackState?
    private var appearances: [ManagedStackIdentity: ManagedStackIdentity] = [:]
    private(set) var failedStopAttempts: [ManagedStackIdentity] = []
    /// `changeState`を呼んでからの観測回数。
    private(set) var observeCalls = 0
    private var scheduledChange: (call: Int, identity: ManagedStackIdentity, state: ManagedStackState?)?
    /// 予約した状態変更を実際に反映した観測の回数目。
    private(set) var appliedChangeAtObserveCall: Int?

    init(base: FakeManagedStackDriver) {
        type = base.type
        self.base = base
    }

    func failStop(of identity: ManagedStackIdentity) {
        failingStops.insert(identity)
    }

    /// 起動を失敗させ、実測上は`state`のまま残す。
    func failStart(leaving state: ManagedStackState) {
        startFailureState = state
    }

    /// `stopped`の停止に成功した直後に、`appearing`が`running`で現れる。
    func appearOnStop(of stopped: ManagedStackIdentity, identity appearing: ManagedStackIdentity) {
        appearances[stopped] = appearing
    }

    /// 今から数えて`call`回目の観測の直前に、`identity`の状態を`state`へ変える（nil は notRunning）。
    func changeState(
        _ identity: ManagedStackIdentity,
        to state: ManagedStackState?,
        beforeObserveCall call: Int
    ) {
        observeCalls = 0
        appliedChangeAtObserveCall = nil
        scheduledChange = (call, identity, state)
    }

    func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot {
        observeCalls += 1
        if let change = scheduledChange, change.call == observeCalls {
            scheduledChange = nil
            appliedChangeAtObserveCall = observeCalls
            await base.setState(change.identity, change.state)
        }
        return await base.observe(known: known)
    }

    var latestSnapshot: ManagedStackSnapshot? {
        get async { await base.latestSnapshot }
    }

    func start(_ stack: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine] {
        if let startFailureState {
            await base.setState(stack.identity, startFailureState)
            throw InjectedFailure(description: "起動に失敗しました（テスト）。")
        }
        return try await base.start(stack, known: known)
    }

    func stop(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine] {
        if failingStops.contains(identity) {
            failedStopAttempts.append(identity)
            throw InjectedFailure(description: "停止に失敗しました（テスト）。")
        }
        let logs = try await base.stop(identity, using: context, known: known)
        if let appearing = appearances[identity] {
            await base.setState(appearing, .running)
        }
        return logs
    }
}
