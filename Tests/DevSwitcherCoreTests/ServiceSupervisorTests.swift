import Darwin
import Foundation
import Testing
@testable import DevSwitcherCore

private let testEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

@Suite("サービスの起動と停止")
struct ServiceSupervisorTests {
    @Test("stdout をログとして受け取り、終了コードを検知する")
    func capturesStandardOutput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "echo",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello dev switcher"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await log.exitStatus == .exited(code: 0))
        #expect(await log.text(of: .stdout).contains("hello dev switcher"))
    }

    @Test("stderr を stdout と区別して受け取る")
    func separatesStandardError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "ls",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/ls"),
                arguments: ["/this-path-does-not-exist"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await !log.text(of: .stderr).isEmpty)
        #expect(await log.text(of: .stdout).isEmpty)
        #expect(await log.exitStatus != .exited(code: 0))
    }

    @Test("指定した作業ディレクトリでコマンドを起動する")
    func launchesInWorkingDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "pwd",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/pwd"),
                arguments: [],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        let printed = await log.text(of: .stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        // /var と /private/var の差を吸収して比較する。
        #expect(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
                == directory.resolvingSymlinksInPath().path
        )
    }

    @Test("起動時にプロセスの同一性を実測して記録する")
    func recordsProcessIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "sleep",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.startedRuntime != nil })
        let runtime = try #require(await log.startedRuntime)

        #expect(runtime.identity.executablePath == "/bin/sleep")
        #expect(runtime.identity.startAbstime > 0)
        #expect(runtime.processGroupID == runtime.identity.pid)
        #expect(ProcessInspector.matchesRunningProcess(runtime.identity))

        let outcome = try await supervisor.stop(grace: .seconds(5))
        #expect(outcome == .exited(.signaled(signal: SIGTERM)))
    }

    @Test("通常終了でプロセスグループごと止め、孫プロセスを残さない")
    func stopsProcessGroupIncludingGrandchild() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "sh",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 120 & echo $!; wait"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await !log.text(of: .stdout).isEmpty })
        let printed = await log.text(of: .stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchildPID = try #require(pid_t(printed))
        #expect(kill(grandchildPID, 0) == 0)

        let runtime = try #require(await log.startedRuntime)
        let outcome = try await supervisor.stop(grace: .seconds(10))

        #expect(outcome == .exited(.signaled(signal: SIGTERM)))
        #expect(ProcessInspector.processGroupState(runtime.processGroupID).hasLiveMembers == false)

        // 孫プロセスも終了している（残っていれば launchd に引き取られて生き続ける）。
        let grandchildGone = await waitUntil(timeout: .seconds(5)) {
            kill(grandchildPID, 0) != 0
        }
        #expect(grandchildGone)
    }

    @Test("listen しているポートを設定値ではなく実測する")
    func observesListeningPorts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let port = 39_217
        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "nc",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-l", String(port)],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .milliseconds(300)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        let observed = await waitUntil(timeout: .seconds(20)) {
            await log.observedPorts.contains { $0.port == port }
        }
        let warnings = await log.warnings
        #expect(observed, "実測ポートを取得できなかった: \(warnings)")

        _ = try await supervisor.stop(grace: .seconds(5))
    }

    @Test("サービスの出力はアプリの fd ではなくログファイルへ書き出す")
    func writesOutputToLogFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let serviceID = UUID()
        let supervisor = ServiceSupervisor(
            serviceID: serviceID,
            serviceName: "echo",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["written to file"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })

        let files = ServiceLogFiles(directory: directory, serviceID: serviceID)
        let contents = try String(contentsOf: files.standardOutput, encoding: .utf8)
        #expect(contents.contains("written to file"))
        #expect(FileManager.default.fileExists(atPath: files.standardError.path))
    }

    @Test("新しい起動では前回セッションのログを再読込しない")
    func newStartReplacesPreviousSessionLogs() async throws {
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
        var service = makeService(
            name: "Web",
            ports: [],
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo old-output; echo old-error >&2; while true; do sleep 1; done",
            ],
            workingDirectory: directory
        )
        var project = makeProject(directory: directory, services: [service])

        let firstLog = EventLog()
        let firstStream = try await registry.start(service: service, in: project)
        let firstConsumer = Task { await firstLog.consume(firstStream) }
        #expect(await waitUntil {
            let output = await firstLog.text(of: .stdout)
            let error = await firstLog.text(of: .stderr)
            return output.contains("old-output") && error.contains("old-error")
        })
        _ = try await registry.stop(service: service, grace: .seconds(2))
        await firstConsumer.value

        service.start.arguments = [
            "-c",
            "echo new-output; echo new-error >&2; while true; do sleep 1; done",
        ]
        project.services = [try #require(service.processDefinition)]

        let secondLog = EventLog()
        let secondStream = try await registry.start(service: service, in: project)
        let secondConsumer = Task { await secondLog.consume(secondStream) }
        defer { secondConsumer.cancel() }
        #expect(await waitUntil {
            let output = await secondLog.text(of: .stdout)
            let error = await secondLog.text(of: .stderr)
            return output.contains("new-output") && error.contains("new-error")
        })

        let secondStandardOutput = await secondLog.text(of: .stdout)
        let secondStandardError = await secondLog.text(of: .stderr)
        #expect(secondStandardOutput.contains("old-output") == false)
        #expect(secondStandardError.contains("old-error") == false)

        let files = ServiceLogFiles(directory: directory, serviceID: service.id)
        let outputFile = try String(contentsOf: files.standardOutput, encoding: .utf8)
        let errorFile = try String(contentsOf: files.standardError, encoding: .utf8)
        #expect(outputFile.contains("new-output"))
        #expect(outputFile.contains("old-output") == false)
        #expect(errorFile.contains("new-error"))
        #expect(errorFile.contains("old-error") == false)

        _ = try await registry.stop(service: service, grace: .seconds(2))
    }

    @Test("停止操作なしの終了は、終了コード 0 でも停止操作と区別する")
    func reportsUnrequestedExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "true",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await log.exitStatus == .exited(code: 0))
        #expect(await log.exitWasRequested == false)
    }

    @Test("停止操作による終了は停止操作として通知する")
    func reportsRequestedExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "sleep",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.startedRuntime != nil })
        _ = try await supervisor.stop(grace: .seconds(5))

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await log.exitWasRequested == true)
    }

    @Test("同一性を観測できないまま親が終了しても、残った孫を占有中として扱う")
    func occupiesResourcesWithoutObservedIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "detached",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 120 &"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            identityProbe: { _, _ in nil }
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        #expect(await supervisor.observedRuntime == nil)
        #expect(await supervisor.isOccupyingResources())

        let processGroupID = try #require(await supervisor.processGroupID)
        let outcome = try await supervisor.stop(grace: .seconds(5))
        guard case .exited = outcome else {
            Issue.record("孫プロセスを停止できなかった: \(outcome)")
            _ = try? await supervisor.forceStop()
            return
        }
        #expect(ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false)
        #expect(await !supervisor.isOccupyingResources())
    }

    @Test("残存を管理している間はリーダーを回収せず、解放後は所有権を手放す")
    func retainsProcessGroupOwnershipWhileResidual() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "detached",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2 &"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })
        let runtime = try #require(await log.startedRuntime)
        let processGroupID = try #require(await supervisor.processGroupID)

        #expect(await supervisor.isOccupyingResources())

        // 後続のシグナルを別グループへ誤送信しないよう、ゾンビでPIDとPGIDを予約する。
        let members = try #require(ProcessInspector.processGroupMembers(processGroupID))
        #expect(members.contains { $0.pid == runtime.identity.pid && $0.isZombie })
        #expect(members.contains { !$0.isZombie })

        let released = await waitUntil(timeout: .seconds(15)) {
            await !supervisor.isOccupyingResources()
        }
        #expect(released)
        #expect(ProcessInspector.processGroupMembers(processGroupID) == [])

        await #expect(throws: RuntimeError.self) {
            _ = try await supervisor.stop(grace: .seconds(1))
        }
        await #expect(throws: RuntimeError.self) {
            _ = try await supervisor.forceStop(grace: .seconds(1))
        }
    }

    @Test("プロセスグループの状態を取得できないときは、停止済みと決めつけない")
    func treatsUnavailableGroupStateAsOccupied() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 観測に失敗し続ける状況を再現する。
        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "echo",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["done"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            groupStateProbe: { _ in .unavailable(errno: EPERM) }
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: testEnvironment)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.exitStatus != nil })

        // 取得できない間は「残っているかもしれない」側に倒す。
        #expect(await supervisor.isOccupyingResources())
        // 所有権も手放さない（手放すと停止手段を失う）。
        #expect(await supervisor.processGroupID != nil)
        // 握りつぶさず警告として見せる。
        #expect(await waitUntil(timeout: .seconds(3)) { await !log.warnings.isEmpty })

        // 停止操作でも「終了した」と決めつけず、残存として返す。
        let outcome = try await supervisor.stop(grace: .milliseconds(300))
        guard case .residual = outcome else {
            Issue.record("観測できないのに停止済みとして扱われた: \(outcome)")
            return
        }
    }

    @Test("動いているのに同一性を観測できない場合は起動を取り消す")
    func cancelsLaunchWhenIdentityIsUnavailable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "sleep",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["120"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            identityProbe: { _, _ in nil }
        )

        do {
            _ = try await supervisor.start(environment: testEnvironment)
            Issue.record("起動が取り消されなかった")
        } catch let error as RuntimeError {
            guard case let .identityUnavailable(_, _, residual) = error else {
                Issue.record("想定と違うエラー: \(error)")
                return
            }
            #expect(residual == nil)
        }

        #expect(await !supervisor.isOccupyingResources())
    }

    @Test("起動取消の通常終了が効かない場合は残存として返す")
    func launchCancellationReportsResidualProcesses() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // SIGTERM を無視し、同一性も観測できない状況を重ねる。
        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "stubborn",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            identityProbe: { _, _ in nil }
        )

        var residualProcessGroupID: pid_t?
        do {
            _ = try await supervisor.start(environment: testEnvironment)
            Issue.record("起動が取り消されなかった")
        } catch let error as RuntimeError {
            guard case let .identityUnavailable(_, _, residual) = error else {
                Issue.record("想定と違うエラー: \(error)")
                return
            }
            residualProcessGroupID = residual
        }

        let processGroupID = try #require(residualProcessGroupID)
        #expect(await supervisor.isOccupyingResources())
        #expect(await supervisor.processGroupID == processGroupID)

        let outcome = try await supervisor.forceStop(grace: .seconds(5))
        guard case .exited = outcome else {
            Issue.record("強制終了できなかった: \(outcome)")
            return
        }
        #expect(await !supervisor.isOccupyingResources())
    }

    @Test("ログ出力にアプリ側の fd を使わない")
    func doesNotHoldDescriptorsForServiceOutput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = ServiceLogFiles(directory: directory, serviceID: UUID())
        let spawned = try ProcessRunner.spawn(
            ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while true; do echo tick; sleep 0.2; done"],
                workingDirectory: directory
            ),
            environment: testEnvironment,
            output: .files(
                standardOutput: files.standardOutput,
                standardError: files.standardError
            )
        )
        defer { kill(-spawned.processGroupID, SIGKILL) }

        #expect(spawned.stdoutFD == nil)
        #expect(spawned.stderrFD == nil)

        let wroteRepeatedly = await waitUntil(timeout: .seconds(10)) {
            let text = (try? String(contentsOf: files.standardOutput, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "tick").count - 1 >= 3
        }
        #expect(wroteRepeatedly)
        #expect(ProcessInspector.processGroupState(spawned.processGroupID).hasLiveMembers == true)
    }

    @Test("起動していないサービスの停止はエラーになる")
    func stoppingNotRunningServiceFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "echo",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: [],
                workingDirectory: directory
            ),
            logDirectory: directory
        )

        await #expect(throws: RuntimeError.self) {
            _ = try await supervisor.stop()
        }
    }
}

@Suite("プロセスの同一性")
struct ProcessIdentityTests {
    @Test("開始時刻と実行ファイルで同一プロセスを判定する")
    func matchesRunningProcess() throws {
        let identity = try #require(
            ProcessInspector.identity(pid: getpid(), workingDirectory: URL(fileURLWithPath: "/"))
        )
        #expect(ProcessInspector.matchesRunningProcess(identity))
    }

    @Test("PID が同じでも開始時刻が違えば別プロセスとして扱う")
    func rejectsRecycledPID() throws {
        let identity = try #require(
            ProcessInspector.identity(pid: getpid(), workingDirectory: URL(fileURLWithPath: "/"))
        )
        let recycled = ProcessIdentity(
            pid: identity.pid,
            startAbstime: identity.startAbstime &+ 1,
            startedAt: identity.startedAt,
            executablePath: identity.executablePath,
            workingDirectory: identity.workingDirectory
        )
        #expect(!ProcessInspector.matchesRunningProcess(recycled))
    }

    @Test("exec で実行ファイルが変わっても同じプロセスとして扱う")
    func execReplacementIsStillTheSameProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // macOS の /bin/sh は起動直後に /bin/bash を exec する。
        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "sh",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 60"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60)
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: ["PATH": "/usr/bin:/bin"])
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }

        #expect(await waitUntil { await log.startedRuntime != nil })
        let runtime = try #require(await log.startedRuntime)

        _ = await waitUntil(timeout: .seconds(3)) {
            ProcessInspector.executablePath(pid: runtime.identity.pid) != runtime.identity.executablePath
        }
        #expect(ProcessInspector.matchesRunningProcess(runtime.identity))

        let outcome = try await supervisor.stop(grace: .seconds(5))
        #expect(outcome == .exited(.signaled(signal: SIGTERM)))
    }

    @Test("存在しない PID は観測できない")
    func missingProcessIsNil() {
        // 使用中でない PID を探す（存在すれば nil にはならないため、確実に空いている値を選ぶ）。
        var candidate: pid_t = 200_000
        while kill(candidate, 0) == 0 || errno == EPERM {
            candidate += 1
        }
        #expect(ProcessInspector.identity(pid: candidate, workingDirectory: URL(fileURLWithPath: "/")) == nil)
        #expect(ProcessInspector.processGroupState(candidate).hasLiveMembers == false)
    }


    @Test("外部で回収されて所有権を失ったら、停止も強制終了もシグナルを送らない")
    func doesNotSignalAfterLosingOwnership() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = SignalRecorder()
        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "Sleep",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            // 回収後に同じPGIDが別グループを指している状況を再現する。
            groupStateProbe: { _ in
                .members([ProcessInspector.ProcessGroupMember(pid: 777, isZombie: false)])
            },
            signalSender: { processGroupID, signal in recorder.send(processGroupID, signal) }
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: fixedShellEnvironment.variables)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }
        let runtime = try #require(await waitForValue { await log.startedRuntime })

        // 外部が先に回収する。ここから先、この PGID は再利用されうる。
        kill(runtime.identity.pid, SIGKILL)
        #expect(await waitUntil {
            var status: Int32 = 0
            return waitpid(runtime.identity.pid, &status, WNOHANG) != 0
        })

        // 所有権喪失を専用結果で返し、古い PGID を残存扱いしない。
        let outcome = try await supervisor.stop(grace: .milliseconds(300))
        #expect(outcome == .ownershipLost)
        #expect(recorder.count == 0, "所有権を失った PGID へ \(recorder.signals) を送った")

        // 占有判定も強制終了導線も、失った PGID を参照しない。
        #expect(await supervisor.isOccupyingResources() == false)
        #expect(await supervisor.processGroupID == nil)
        await #expect(throws: RuntimeError.self) {
            _ = try await supervisor.forceStop(grace: .milliseconds(300))
        }
        #expect(recorder.count == 0)
    }


    @Test("ポートを実測できなければ、0件ではなく不明として記録する")
    func failedPortMeasurementIsRecordedAsUnavailable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supervisor = ServiceSupervisor(
            serviceID: UUID(),
            serviceName: "Sleep",
            command: ResolvedCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory
            ),
            logDirectory: directory,
            portPollInterval: .seconds(60),
            portProbe: { _ in
                throw PortInspectorError.unparsableOutput(line: "broken")
            }
        )

        let log = EventLog()
        let stream = try await supervisor.start(environment: fixedShellEnvironment.variables)
        let consumer = Task { await log.consume(stream) }
        defer { consumer.cancel() }
        #expect(await waitForValue { await log.startedRuntime } != nil)

        await #expect(throws: PortInspectorError.self) {
            try await supervisor.refreshPorts()
        }
        #expect(await supervisor.observedPortRecord == .unavailable)

        _ = try? await supervisor.stop(grace: .seconds(5))
    }
}
