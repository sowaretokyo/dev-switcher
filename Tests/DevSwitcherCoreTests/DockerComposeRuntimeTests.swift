import Foundation
import Testing
@testable import DevSwitcherCore

private actor ComposeRunnerFake: ManagedStackCommandRunning {
    var records: [(CommandSpec, ManagedStackCommandPolicy)] = []
    var observations: [String]
    var failure = false
    init(_ observations: [String]) { self.observations = observations }
    func run(_ command: CommandSpec, policy: ManagedStackCommandPolicy) async throws -> ManagedStackCommandResult {
        records.append((command, policy))
        try ComposeCommandRules.validateCommand(command)
        if failure { throw ComposeConfigurationError.invalid("Docker unavailable") }
        var output = ""
        if command.arguments.suffix(4) == ["ps", "--all", "--format", "json"], !observations.isEmpty {
            output = observations.count > 1 ? observations.removeFirst() : observations[0]
        }
        return ManagedStackCommandResult(status: .exited(code: 0), standardOutput: output, standardError: "")
    }
    func setFailure() { failure = true }
}

@Suite("Compose 観測・起動・停止")
struct DockerComposeRuntimeTests {
    private static func row(_ state: String, _ health: String = "", id: String = "one", project: String = "shop") -> String {
        "{\"ID\":\"\(id)\",\"Project\":\"\(project)\",\"State\":\"\(state)\",\"Health\":\"\(health)\"}"
    }
    private static let classifications: [(String, ManagedStackState)] = [
        ("", ManagedStackState.notRunning), ("[]", .notRunning),
        (row("running"), .running), (row("running", "healthy"), .running),
        (row("exited"), .notRunning), (row("created"), .notRunning), (row("dead"), .notRunning),
        (row("running", "unhealthy"), .degraded), (row("restarting"), .degraded), (row("paused"), .degraded),
        (row("running", "starting"), .unknown), (row("removing"), .unknown), (row("unknown"), .unknown),
        ("[" + row("running") + "," + row("exited", id: "two") + "]", .degraded),
        (row("running") + "\n" + row("running", id: "two"), .running),
        (row("running", "unhealthy") + "\n" + row("removing", id: "two"), .unknown),
        ("{}", .unknown), ("not json", .unknown), (row("running", project: "other"), .unknown),
        (row("running") + "\n" + row("running"), .unknown),
    ]
    @Test("コンテナ状態を優先順位どおり分類する", arguments: classifications)
    func classify(_ input: (String, ManagedStackState)) throws {
        let identity = try ManagedStackIdentity(type: .dockerCompose, value: "shop")
        #expect(ComposePsParser.observation(input.0, identity: identity).state == input.1)
    }
    private func stack(_ directory: URL) throws -> ResolvedManagedStack {
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        return try ResolvedManagedStack(environmentID: UUID(), definition: ManagedStackDefinition(id: UUID(), name: "DB", configuration: .dockerCompose(.init(projectName: "shop", profiles: ["dev"])), ports: [], enabledByDefault: true, failurePolicy: .block), workingDirectory: directory)
    }
    @Test("既知の ID だけを観測し、失敗は unknown にする")
    func observationScopeAndFailure() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let stack = try stack(directory), runner = ComposeRunnerFake([Self.row("running")])
        let driver = DockerComposeStackDriver(runner: runner)
        #expect(await driver.observe(known: []).observations.isEmpty)
        #expect(await runner.records.isEmpty)
        #expect(await driver.observe(known: [stack]).state(of: stack.identity) == .running)
        await runner.setFailure()
        #expect(await driver.observe(known: [stack]).state(of: stack.identity) == .unknown)
        let records = await runner.records
        #expect(records.allSatisfy { $0.0.arguments.prefix(3) == ["compose", "-p", "shop"] })
        #expect(records.allSatisfy { $0.1.timeout == .seconds(60) })
    }
    @Test("起動・停止は期限まで再観測して確定する")
    func lifecycleWaitsForState() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let stack = try stack(directory)
        let runner = ComposeRunnerFake([Self.row("running", "starting"), Self.row("running"), Self.row("running"), Self.row("exited")])
        let driver = DockerComposeStackDriver(runner: runner, options: .init(startConfirmationWindow: .seconds(1), stopConfirmationWindow: .seconds(1), pollInterval: .milliseconds(1)))
        _ = try await driver.start(stack, known: [stack])
        #expect(await driver.latestSnapshot?.state(of: stack.identity) == .running)
        _ = try await driver.stop(stack.identity, using: stack, known: [stack])
        #expect(await driver.latestSnapshot?.state(of: stack.identity) == .notRunning)
        let records = await runner.records
        #expect(records.count == 6)
        #expect(records[0].1.timeout == .seconds(300))
        #expect(records[3].0.arguments.last == "stop")
        await #expect(throws: ManagedStackOperationError.self) {
            try await driver.stop(ManagedStackIdentity(type: .dockerCompose, value: "other"), using: stack, known: [stack])
        }
        #expect(await runner.records.count == 6)
    }
    @Test("期限の最終状態が unknown なら成功にしない")
    func deadlineFailure() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let stack = try stack(directory), runner = ComposeRunnerFake([Self.row("running", "starting")])
        let driver = DockerComposeStackDriver(runner: runner, options: .init(startConfirmationWindow: .zero))
        await #expect(throws: ManagedStackOperationError.self) { try await driver.start(stack, known: [stack]) }
        #expect(await driver.latestSnapshot?.state(of: stack.identity) == .unknown)
    }
    @Test("実行境界で禁止コマンドを拒否し、Compose の暗黙環境変数を除去する")
    func runnerPolicy() async throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("docker")
        try "#!/bin/sh\nprintf '%s|%s|%s' \"${COMPOSE_PROJECT_NAME-unset}\" \"${COMPOSE_FILE-unset}\" \"${COMPOSE_PROFILES-unset}\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = try ShellEnvironment(variables: ["PATH": directory.path + ":/usr/bin:/bin", "COMPOSE_PROJECT_NAME": "other", "COMPOSE_FILE": "other.yaml", "COMPOSE_PROFILES": "other"])
        let runner = ManagedStackProcessCommandRunner(environmentProvider: { environment })
        let command = CommandSpec(executable: "docker", arguments: ["compose", "-p", "shop", "-f", "/tmp/compose.yaml", "--profile", "*", "stop"], workingDirectory: directory)
        let result = try await runner.run(command, policy: DockerComposeStackDriver.policy(timeout: .seconds(1)))
        #expect(result.standardOutput == "unset|unset|unset")
        var forbidden = command; forbidden.arguments[forbidden.arguments.count - 1] = "down"
        await #expect(throws: ComposeConfigurationError.self) { try await runner.run(forbidden, policy: DockerComposeStackDriver.policy(timeout: .seconds(1))) }
    }
}
