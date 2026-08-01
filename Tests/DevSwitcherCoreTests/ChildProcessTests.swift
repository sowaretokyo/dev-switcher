import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("子プロセスの回収")
struct ChildProcessTests {
    private func spawnSleep(seconds: String, in directory: URL) throws -> SpawnedProcess {
        try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: [seconds],
                workingDirectory: directory
            ),
            environment: ["PATH": "/usr/bin:/bin"],
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )
    }

    @Test("終了していない子プロセスは回収しない")
    func doesNotReleaseRunningChild() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try spawnSleep(seconds: "30", in: directory)
        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)
        defer { kill(-spawned.processGroupID, SIGKILL) }

        // 動いている間は回収できない。成功したことにしない。
        #expect(child.release() == false)
        #expect(child.isProcessGroupOwned)
        #expect(ProcessInspector.processGroupState(spawned.processGroupID).hasLiveMembers == true)
    }

    @Test("終了後に回収すると所有権を手放す")
    func releasesAfterExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try spawnSleep(seconds: "0", in: directory)
        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)

        let status = await child.waitForExit(timeout: .seconds(5))
        #expect(status == .exited(code: 0))

        // 回収前はゾンビとして残り、PID と PGID を予約している。
        let beforeRelease = try #require(
            ProcessInspector.processGroupMembers(spawned.processGroupID)
        )
        #expect(beforeRelease.contains { $0.pid == spawned.pid && $0.isZombie })

        #expect(child.release())
        #expect(!child.isProcessGroupOwned)
        #expect(ProcessInspector.processGroupMembers(spawned.processGroupID) == [])

        // 二度目以降も破綻しない。
        #expect(child.release())
    }
}
