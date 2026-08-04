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

    @Test("短命な子プロセスの終了を繰り返し取りこぼさない")
    func observesRapidExitReliably() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<32 {
            let spawned = try ProcessRunner.spawn(
                ResolvedCommand(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    workingDirectory: directory
                ),
                environment: ["PATH": "/usr/bin:/bin"],
                output: .files(
                    standardOutput: directory.appendingPathComponent("rapid-\(index)-out.log"),
                    standardError: directory.appendingPathComponent("rapid-\(index)-err.log")
                )
            )
            let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)

            let status = await child.waitForExit(timeout: .seconds(2))
            #expect(status == .exited(code: 0), "\(index + 1)回目の終了状態を取得できなかった")
            #expect(child.release(), "\(index + 1)回目の子プロセスを回収できなかった")
        }
    }

    @Test("補助コマンドを制御TTYから切り離した新規セッションで起動する")
    func startsHelperInNewSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            environment: ["PATH": "/usr/bin:/bin"],
            output: .files(
                standardOutput: directory.appendingPathComponent("session-out.log"),
                standardError: directory.appendingPathComponent("session-err.log")
            ),
            isolation: .session
        )
        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)

        #expect(getsid(spawned.pid) == spawned.pid)
        kill(-spawned.processGroupID, SIGTERM)
        #expect(await child.waitForExit(timeout: .seconds(2)) == .signaled(signal: SIGTERM))
        #expect(child.release())
    }

    @Test("終了通知が来ない場合でも、最初の読み取りで終了を検知する")
    func detectsExitSynchronouslyWithoutNotification() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 3"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out.log"),
                standardError: directory.appendingPathComponent("err.log")
            )
        )

        // 監視を始める前に終了させる。この場合、終了通知は二度と配送されない。
        #expect(await waitUntil {
            ProcessInspector.processGroupState(spawned.processGroupID)
                .hasLiveMembers == false
        })

        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)
        // 通知や 250ms のポーリングを待たずに、読んだ時点で終了を返す。
        // ここが nil のままだと、既に終了したプロセスをヘルスチェックが通す。
        #expect(child.currentStatus == .exited(code: 3))
        #expect(child.release())
    }

    @Test("終了済みのプロセスを待つとき、猶予を使い切らない")
    func waitForExitReturnsImmediatelyForFinishedProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"],
                workingDirectory: directory
            ),
            environment: fixedShellEnvironment.variables,
            output: .files(
                standardOutput: directory.appendingPathComponent("out2.log"),
                standardError: directory.appendingPathComponent("err2.log")
            )
        )
        #expect(await waitUntil {
            ProcessInspector.processGroupState(spawned.processGroupID)
                .hasLiveMembers == false
        })

        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)
        let started = ContinuousClock.now
        let status = await child.waitForExit(timeout: .seconds(5))
        let elapsed = ContinuousClock.now - started

        #expect(status == .exited(code: 0))
        // 待機登録の前に観測するので、通知待ちで猶予を消費しない。
        #expect(elapsed < .seconds(1))
        #expect(child.release())
    }
}
