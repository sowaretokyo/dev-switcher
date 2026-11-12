import Foundation
import Testing
@testable import DevSwitcherCore

private actor ComposeLifecycleWorld: ManagedStackCommandRunning {
    var state: ManagedStackState
    var mutation: [String] = []
    var states: [String: ManagedStackState] = [:]
    var failStartLeavingRunning = false
    init(_ state: ManagedStackState) { self.state = state }
    func failStart() { failStartLeavingRunning = true }
    func run(_ command: CommandSpec, policy: ManagedStackCommandPolicy) async throws -> ManagedStackCommandResult {
        try ComposeCommandRules.validateCommand(command)
        let args = command.arguments
        let name = args[2]
        if args.contains("up") {
            mutation.append("up"); states[name] = .running
            if failStartLeavingRunning { return .init(status: .exited(code: 1), standardOutput: "", standardError: "failed after create") }
        } else if args.last == "stop" { mutation.append("stop"); states[name] = .notRunning }
        var output = ""
        if args.contains("ps") {
            switch states[name] ?? state {
            case .notRunning: output = "[]"
            case .running: output = #"{"ID":"one","Project":"shop","State":"running","Health":""}"#
            case .degraded: output = #"{"ID":"one","Project":"shop","State":"running","Health":"unhealthy"}"#
            case .unknown: output = "unparseable"
            }
        }
        output = output.replacingOccurrences(of: "shop", with: name)
        return .init(status: .exited(code: 0), standardOutput: output, standardError: "")
    }
}

@Suite("Compose の切替と確認")
struct DockerComposeCoordinatorTests {
    private func fixture(_ directory: URL, _ state: ManagedStackState) throws -> (ProjectDefinition, RuntimeRegistry, SwitchCoordinator, ComposeLifecycleWorld) {
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let stack = ManagedStackDefinition(id: UUID(), name: "Compose", configuration: .dockerCompose(.init(projectName: "shop")), ports: [], enabledByDefault: true, failurePolicy: .continue)
        let project = ProjectDefinition(name: "Shop", color: .blue, workingDirectories: [.init(name: "App", directory: directory, serviceIDs: [], stackIDs: [stack.id])], services: [DevSwitcherCore.ServiceDefinition](), managedStacks: [stack])
        let world = ComposeLifecycleWorld(state)
        let driver = DockerComposeStackDriver(runner: world, options: .init(startConfirmationWindow: .zero, stopConfirmationWindow: .zero))
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, stackDrivers: [.dockerCompose: driver])
        return (project, registry, SwitchCoordinator(registry: registry), world)
    }
    private func plan(_ coordinator: SwitchCoordinator, _ project: ProjectDefinition) async throws -> ManagedStackConfirmationPlan {
        do { _ = try await coordinator.start(project, registeredProjects: [project]) }
        catch let error as SwitchFailure {
            if case let .managedStackConfirmationRequired(plan) = error.reason { return plan }
            throw error
        }
        Issue.record("確認が要求されませんでした")
        throw CancellationError()
    }
    @Test("running は承認後に起動せず引き継ぎ、通常停止で対象を停止する")
    func adoptThenStop() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (project, registry, coordinator, world) = try fixture(directory, .running)
        let plan = try await plan(coordinator, project)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].identity.type == .dockerCompose)
        #expect(plan.entries[0].action == .adopt)
        #expect(await world.mutation.isEmpty)
        _ = try await coordinator.start(project, registeredProjects: [project], approval: plan.approval)
        #expect(await world.mutation.isEmpty)
        #expect(try await registry.managedRuntimeHints().first?.relationship == .adopted)
        _ = try await coordinator.stop(project, registeredProjects: [project])
        #expect(await world.mutation == ["stop"])
        #expect(await registry.isOccupyingResources(serviceID: project.managedStacks[0].id) == false)
    }
    @Test("degraded は承認後だけ stop と up で復旧する")
    func restartDegraded() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (project, _, coordinator, world) = try fixture(directory, .degraded)
        let plan = try await plan(coordinator, project)
        #expect(plan.entries[0].action == .restart)
        #expect(await world.mutation.isEmpty)
        _ = try await coordinator.start(project, registeredProjects: [project], approval: plan.approval)
        #expect(await world.mutation == ["stop", "up"])
    }
    @Test("unknown と、起動失敗後の外部占有は continue でも変更・自動停止しない", arguments: [true, false])
    func noMutationWithoutOwnership(unknown: Bool) async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (project, registry, coordinator, world) = try fixture(directory, unknown ? .unknown : .notRunning)
        if !unknown { await world.failStart() }
        await #expect(throws: SwitchFailure.self) { try await coordinator.start(project, registeredProjects: [project]) }
        #expect(await world.mutation == (unknown ? [] : ["up"]))
        #expect(try await registry.managedRuntimeHints().isEmpty)
    }
}

private final class LaunchOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

extension DockerComposeCoordinatorTests {
    @Test("Supabase と複数 Compose を登録順に先行起動し、プロセスの後に逆順で停止する")
    func mixedStacksAndProcessOrder() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "shop", in: directory)
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let supabase = try #require(makeSupabaseService(workingDirectory: directory).managedStackDefinition)
        let one = ManagedStackDefinition(id: UUID(), name: "Compose one", configuration: .dockerCompose(.init(projectName: "shop")), ports: [], enabledByDefault: true, failurePolicy: .block)
        var two = one; two.id = UUID(); two.name = "Compose two"; two.configuration = .dockerCompose(.init(projectName: "workerdb"))
        let worker = try #require(makeService(name: "Worker", kind: .worker, ports: [], executable: "/bin/sleep", arguments: ["30"], workingDirectory: directory).processDefinition)
        let project = ProjectDefinition(name: "Shop", color: .blue, workingDirectories: [.init(name: "App", directory: directory, serviceIDs: [worker.id], stackIDs: [supabase.id, one.id, two.id])], services: [worker], managedStacks: [supabase, one, two])
        let compose = ComposeLifecycleWorld(.notRunning), supabaseWorld = FakeSupabaseWorld()
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, stackDrivers: [
            .dockerCompose: DockerComposeStackDriver(runner: compose, options: .init(startConfirmationWindow: .zero, stopConfirmationWindow: .zero)),
            .supabase: SupabaseStackDriver(inventory: supabaseWorld, runner: supabaseWorld),
        ])
        let coordinator = SwitchCoordinator(registry: registry, options: .init(startupObservationWindow: .milliseconds(30), startupPollInterval: .milliseconds(5)))
        let starting = LaunchOrderRecorder(), stopping = LaunchOrderRecorder()
        _ = try await coordinator.start(project, registeredProjects: [project], progress: { step in
            if case let .starting(service, _, _) = step { starting.append(service) }
        })
        #expect(starting.snapshot() == ["Supabase", "Compose one", "Compose two", "Worker"])
        _ = try await coordinator.stop(project, registeredProjects: [project], progress: { step in
            if case let .stopping(service, _, _) = step { stopping.append(service) }
        })
        #expect(stopping.snapshot() == ["Worker", "Compose two", "Compose one", "Supabase"])
        #expect(await registry.occupyingServiceIDs(projectID: project.id).isEmpty)
    }
}
