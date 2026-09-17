import Darwin
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("テスト用プロセスの掃除")
struct TestProcessCleanupTests {
    private enum FixtureError: Error {
        case setupFailed
    }

    @Test("リーダーが終了済みでも回収し、残った子孫も掃除する", arguments: [false, true])
    func cleanupAfterLeaderExit(hasLiveDescendant: Bool) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", hasLiveDescendant ? "sleep 120 &\nexit 0" : "exit 0"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("cleanup-out.log"),
                standardError: directory.appendingPathComponent("cleanup-err.log")
            )
        )
        let cleanup = TestProcessGroupCleanup(spawned)
        defer { #expect(cleanup.cleanUp()) }

        // waitpid で回収せず、終了済みのリーダーが残る状態を確実に作る。
        try #require(await waitForZombieLeader(spawned))
        #expect(ProcessInspector.processGroupState(spawned.processGroupID).hasLiveMembers == hasLiveDescendant)

        #expect(cleanup.cleanUp())
        #expect(ProcessInspector.processGroupState(spawned.processGroupID).hasLiveMembers == false)
        var rawStatus: Int32 = 0
        let waitResult = waitpid(spawned.pid, &rawStatus, WNOHANG)
        let waitError = errno
        #expect(waitResult == -1 && waitError == ECHILD)
    }

    @Test("setup が途中で失敗しても孫を含むプロセスグループを掃除する")
    func cleanupAfterSetupFailure() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var spawnedProcessGroupID: pid_t?
        do {
            try await createFailingProcessFixture(in: directory) {
                spawnedProcessGroupID = $0
            }
            Issue.record("fixture の setup が失敗しませんでした。")
        } catch FixtureError.setupFailed {
            // 想定した setup 失敗。
        }

        let processGroupID = try #require(spawnedProcessGroupID)
        defer { kill(-processGroupID, SIGKILL) }

        #expect(await waitForGroupToDrain(processGroupID))
    }

    private func createFailingProcessFixture(
        in directory: URL,
        onSpawn: (pid_t) -> Void
    ) async throws {
        let testProcessID = getpid()
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    sleep 120 &
                    child=$!
                    trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null' 0
                    remaining=1200
                    while kill -0 \(testProcessID) 2>/dev/null && [ -d "\(directory.path)" ] && [ "$remaining" -gt 0 ]; do
                      remaining=$((remaining - 1))
                      sleep 0.05
                    done
                    """,
                ],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("cleanup-out.log"),
                standardError: directory.appendingPathComponent("cleanup-err.log")
            )
        )
        let cleanup = TestProcessGroupCleanup(spawned)
        onSpawn(spawned.processGroupID)

        #expect(await waitForGroupMemberCount(2, processGroupID: spawned.processGroupID))
        withExtendedLifetime(cleanup) {}
        throw FixtureError.setupFailed
    }

    private func waitForZombieLeader(_ spawned: SpawnedProcess) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case let .members(members) = ProcessInspector.processGroupState(spawned.processGroupID),
               members.contains(where: { $0.pid == spawned.pid && $0.isZombie }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForGroupMemberCount(
        _ expectedCount: Int,
        processGroupID: pid_t
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case let .members(members) = ProcessInspector.processGroupState(processGroupID),
               members.filter({ !$0.isZombie }).count >= expectedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForGroupToDrain(_ processGroupID: pid_t) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false
    }
}
