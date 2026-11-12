import Darwin
import Foundation

struct CapturedOutput: Sendable {
    let status: ExitStatus
    let standardOutput: Data
    let standardError: Data

    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum CommandOutputError: Error, Sendable, CustomStringConvertible {
    case timedOut(executable: String, seconds: Double)

    var description: String {
        switch self {
        case let .timedOut(executable, seconds):
            L10n.text("\(executable) が \(Int(seconds)) 秒以内に終了しませんでした。")
        }
    }
}

enum CommandOutput {
    static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: Duration
    ) async throws -> CapturedOutput {
        let command = ResolvedCommand(
            executableURL: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
        let spawned = try ProcessRunner.spawn(
            command,
            environment: environment,
            output: .pipes,
            isolation: .session
        )
        let child = ChildProcess(pid: spawned.pid, processGroupID: spawned.processGroupID)
        guard let stdoutFD = spawned.stdoutFD, let stderrFD = spawned.stderrFD else {
            kill(-spawned.processGroupID, SIGKILL)
            throw ProcessSpawnError.pipeCreationFailed(errno: EBADF)
        }
        let queue = DispatchQueue(label: "jp.devswitcher.capture.\(spawned.pid)")

        // pipe が詰まって子が止まらないよう、待ち合わせ前に読み出しを開始する。
        async let standardOutput = readToEnd(fileDescriptor: stdoutFD, queue: queue)
        async let standardError = readToEnd(fileDescriptor: stderrFD, queue: queue)

        guard let status = await child.waitForExit(timeout: timeout) else {
            // 補助コマンドの停止はサービス管理と違い、利用者の確認を待たない。
            kill(-spawned.processGroupID, SIGKILL)
            _ = await child.waitForExit(timeout: .seconds(2))
            _ = await standardOutput
            _ = await standardError
            throw CommandOutputError.timedOut(
                executable: executable.path,
                seconds: timeout.seconds
            )
        }

        return CapturedOutput(
            status: status,
            standardOutput: await standardOutput,
            standardError: await standardError
        )
    }

    private static func readToEnd(fileDescriptor: Int32, queue: DispatchQueue) async -> Data {
        await withCheckedContinuation { continuation in
            let box = DataBox()
            let channel = DispatchIO(
                type: .stream,
                fileDescriptor: fileDescriptor,
                queue: queue
            ) { _ in
                close(fileDescriptor)
            }
            channel.setLimit(lowWater: 1)
            channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
                if let data, !data.isEmpty {
                    box.append([UInt8](data))
                }
                if done {
                    continuation.resume(returning: box.data)
                    // チャンネルを読み出し完了まで保持する。
                    withExtendedLifetime(channel) {}
                }
            }
        }
    }
}

/// `@unchecked Sendable` の可変状態は、呼び出し側のシリアルキューだけから触る。
private final class DataBox: @unchecked Sendable {
    private(set) var data = Data()

    func append(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }
}
