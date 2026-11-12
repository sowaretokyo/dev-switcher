import Foundation
import Testing
@testable import DevSwitcherCore

/// driver・コマンド実行器・Registry の種類共通の契約（docs/ARCHITECTURE.md 4.2）。
@Suite("管理対象スタックの Runtime 契約")
struct ManagedStackRuntimeTests {
    // MARK: - Supabase driver の実行境界

    @Test("Supabase driver は status・start・stop のすべてに Supabase の policy を渡す")
    func supabaseDriverPassesPolicyToEveryCommand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "demo", in: directory)
        let service = makeSupabaseService(workingDirectory: directory)
        let stack = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("demo"))
        let world = FakeSupabaseWorld()
        let driver = SupabaseStackDriver(
            inventory: world,
            runner: world,
            options: SupabaseStackDriver.Options(
                startConfirmationWindow: .milliseconds(300),
                stopConfirmationWindow: .milliseconds(300),
                pollInterval: .milliseconds(10)
            )
        )

        _ = try await driver.start(stack, known: [stack])
        // 設定が既知で DB が healthy なので、観測は status まで確認する。
        let snapshot = await driver.observe(known: [stack])
        #expect(snapshot.state(of: stack.identity) == .running)
        _ = try await driver.stop(stack.identity, using: stack, known: [stack])

        let commands = await world.commands.map(\.arguments)
        #expect(commands.contains { $0.contains("start") })
        #expect(commands.contains { $0.contains("status") })
        #expect(commands.contains { $0.contains("stop") })
        let policies = await world.policies
        #expect(policies.count == commands.count)
        #expect(policies.allSatisfy { $0 == SupabaseStackDriver.commandPolicy })
        #expect(SupabaseStackDriver.commandPolicy.forbiddenArguments == ["--all", "--no-backup"])
        #expect(SupabaseStackDriver.commandPolicy.removedEnvironmentKeys == ["SUPABASE_WORKDIR"])
    }

    // MARK: - 実プロセスの実行器

    @Test("実プロセスの実行器は、渡された policy で禁止引数を完全一致で拒否し、環境変数を除く")
    func processRunnerAppliesGivenPolicy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-tool")
        let marker = directory.appendingPathComponent("ran")
        try Data("""
            #!/bin/sh
            : > "\(marker.path)"
            test "${FAKE_TARGET+x}" != x || exit 42
            printf '%s\\n' "$FAKE_KEEP" "$@"
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = try ShellEnvironment(variables: [
            "PATH": directory.path + ":/usr/bin:/bin",
            "FAKE_TARGET": "/unexpected",
            "FAKE_KEEP": "preserved",
        ])
        let policy = ManagedStackCommandPolicy(
            forbiddenArguments: ["--danger"],
            removedEnvironmentKeys: ["FAKE_TARGET"]
        )
        let runner = ManagedStackProcessCommandRunner(environmentProvider: { environment })

        await #expect(throws: ManagedStackCommandError.forbiddenOption(
            command: "fake-tool run --danger",
            option: "--danger"
        )) {
            _ = try await runner.run(
                CommandSpec(executable: "fake-tool", arguments: ["run", "--danger"], workingDirectory: directory),
                policy: policy
            )
        }
        // 拒否したコマンドは起動していない。
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // 完全一致でないトークンは拒否しない。除いた環境変数は渡らず、他の値は残る。
        let result = try await runner.run(
            CommandSpec(executable: "fake-tool", arguments: ["run", "--danger-zone"], workingDirectory: directory),
            policy: policy
        )
        #expect(result.isSuccess)
        #expect(result.standardOutput.split(separator: "\n").map(String.init)
            == ["preserved", "run", "--danger-zone"])
    }

    // MARK: - Registry

    private func makeRegistry(
        driver: FakeManagedStackDriver,
        directory: URL
    ) -> RuntimeRegistry {
        RuntimeRegistry(
            portPollInterval: .seconds(60),
            logDirectory: directory,
            environmentLoader: { fixedShellEnvironment },
            portProbe: { _ in [] },
            stackDrivers: [.supabase: driver]
        )
    }

    @Test("登録済みも管理下も無ければ driver を呼ばない")
    func registryDoesNotCallDriverWithoutStacks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = FakeManagedStackDriver(type: .supabase)
        let registry = makeRegistry(driver: driver, directory: directory)

        let refreshed = await registry.refreshManagedObservations()
        let observed = await registry.observeManagedStacks()

        #expect(await driver.calls.isEmpty)
        #expect(!refreshed.hasResult(for: .supabase))
        #expect(!observed.hasResult(for: .supabase))
        #expect(await registry.latestManagedStackSnapshot() == nil)
    }

    @Test("種類共通の driver だけで、Registry の起動・引き継ぎ・未管理の停止・観測と handle の解除が動く")
    func registryWorksWithFakeDriverOnly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeSupabaseService(workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        let stack = try makeResolvedSupabaseStack(service, projectID: makeSupabaseProjectID("demo"), environmentID: project.id)
        let other = try ManagedStackIdentity(type: .supabase, value: "other")
        let driver = FakeManagedStackDriver(type: .supabase)
        let registry = makeRegistry(driver: driver, directory: directory)
        await registry.setKnownStacks([stack.identity: stack])

        // 起動: 直前の実測が notRunning のときだけ start し、launched として管理する。
        _ = try await registry.startManagedStack(stack, in: project)
        #expect(await driver.calls == [
            .observe(known: [stack.identity]),
            .start(stack.identity, known: [stack.identity]),
        ])
        #expect(await registry.managedRelationship(stackID: service.id) == .launched)
        #expect(await registry.managedStackIdentities() == [service.id: stack.identity])
        #expect(await registry.isRunning(serviceID: service.id))

        // 観測: notRunning を実測したら handle を外す。
        await driver.setState(stack.identity, nil)
        let stopped = await registry.observeManagedStacks()
        #expect(stopped.state(of: stack.identity) == .notRunning)
        #expect(await registry.managedRelationship(stackID: service.id) == nil)
        #expect(await registry.managedObservation(stackID: service.id) == nil)
        #expect(await registry.managedStackIdentities().isEmpty)
        #expect(await registry.latestManagedStackSnapshot() == stopped)

        // 引き継ぎ: 起動コマンドを実行せずに管理下へ置き、管理関係で停止する。
        await driver.setState(stack.identity, .running)
        await driver.resetCalls()
        _ = try await registry.adoptManagedStack(
            stack,
            in: project,
            relationship: .adopted,
            observation: ManagedStackObservation(identity: stack.identity, state: .running)
        )
        #expect(await driver.calls.isEmpty)
        #expect(await registry.managedRelationship(stackID: service.id) == .adopted)
        let outcome = try await registry.stop(service: service)
        #expect(outcome == .stopped(nil))
        #expect(await driver.calls == [
            .stop(stack.identity, context: stack.identity, known: [stack.identity]),
        ])
        #expect(await registry.managedRelationship(stackID: service.id) == nil)

        // 未管理の停止: 指定した ID だけを、context の設定で停止する。
        await driver.setState(other, .running)
        await driver.resetCalls()
        try await registry.stopUnmanagedStack(other, using: stack)
        #expect(await driver.calls == [
            .stop(other, context: stack.identity, known: [stack.identity]),
        ])
        let afterStop = await registry.observeManagedStacks()
        #expect(afterStop.state(of: other) == .notRunning)
        #expect(await registry.managedStackIdentities().isEmpty)
    }
}
