import Darwin
import Foundation

public enum SpawnOutput: Sendable {
    /// アプリが所有する pipe。アプリが終了すると読み出し側が閉じるため、
    /// アプリより長く生きるプロセスには使わない。固定の補助コマンド専用。
    case pipes
    /// アプリ終了後も残すサービスには、読み手の寿命に依存しないファイルを使う。
    case files(standardOutput: URL, standardError: URL)
}

public enum SpawnIsolation: Sendable {
    /// サービスを親と別のプロセスグループにし、孫を含めて停止できるようにする。
    case processGroup
    /// 固定の補助コマンドを制御TTYから切り離し、孫を含めて停止できるようにする。
    case session
}

public struct SpawnedProcess: Sendable {
    public let pid: pid_t
    /// 子は独立したプロセスグループのリーダーとして起動するため pgid == pid。
    public let processGroupID: pid_t
    public let stdoutFD: Int32?
    public let stderrFD: Int32?
}

public enum ProcessSpawnError: Error, Sendable, CustomStringConvertible {
    case pipeCreationFailed(errno: Int32)
    case spawnFailed(errno: Int32, executable: String)
    case attributeSetupFailed(errno: Int32)
    case logFileUnavailable(path: String)

    public var description: String {
        switch self {
        case let .pipeCreationFailed(code):
            "パイプを作成できませんでした（errno \(code): \(CStringDecoding.errorMessage(code))）。"
        case let .spawnFailed(code, executable):
            "プロセスを起動できませんでした（\(executable) / errno \(code): \(CStringDecoding.errorMessage(code))）。"
        case let .attributeSetupFailed(code):
            "プロセス起動属性を設定できませんでした（errno \(code): \(CStringDecoding.errorMessage(code))）。"
        case let .logFileUnavailable(path):
            "ログファイルを作成できませんでした（\(path)）。"
        }
    }
}

/// シェル文字列による注入を避け、親だけでなく孫まで停止できるよう、
/// 構造化コマンドを独立したプロセスグループとして起動する。
/// アプリ側の不要なfdは、サービスを意図せず生存させないよう継承させない。
public enum ProcessRunner {
    public static func spawn(
        _ command: ResolvedCommand,
        environment: [String: String],
        output: SpawnOutput,
        isolation: SpawnIsolation = .processGroup
    ) throws -> SpawnedProcess {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var openedDescriptors: [Int32] = []

        if case .pipes = output {
            guard pipe(&stdoutPipe) == 0 else {
                throw ProcessSpawnError.pipeCreationFailed(errno: errno)
            }
            guard pipe(&stderrPipe) == 0 else {
                let code = errno
                close(stdoutPipe[0])
                close(stdoutPipe[1])
                throw ProcessSpawnError.pipeCreationFailed(errno: code)
            }
            openedDescriptors = [stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]]
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            let code = errno
            closeAll(openedDescriptors)
            throw ProcessSpawnError.attributeSetupFailed(errno: code)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // 標準入力は端末に繋がない。開発コマンドが対話入力を待って止まるのを防ぐ。
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        switch output {
        case .pipes:
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        case let .files(standardOutput, standardError):
            // pipeだとアプリ終了後の書き込みでSIGPIPEになるため、子自身にファイルを開かせる。
            try prepareLogFile(at: standardOutput)
            try prepareLogFile(at: standardError)
            posix_spawn_file_actions_addopen(
                &fileActions, STDOUT_FILENO, standardOutput.path, O_WRONLY | O_APPEND, 0o644
            )
            posix_spawn_file_actions_addopen(
                &fileActions, STDERR_FILENO, standardError.path, O_WRONLY | O_APPEND, 0o644
            )
        }

        let chdirResult = posix_spawn_file_actions_addchdir_np(
            &fileActions,
            command.workingDirectory.path
        )
        guard chdirResult == 0 else {
            closeAll(openedDescriptors)
            throw ProcessSpawnError.attributeSetupFailed(errno: chdirResult)
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            let code = errno
            closeAll(openedDescriptors)
            throw ProcessSpawnError.attributeSetupFailed(errno: code)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // アプリ側のシグナル設定を引き継がせない。
        var emptySignals = sigset_t()
        sigemptyset(&emptySignals)
        posix_spawnattr_setsigmask(&attributes, &emptySignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        var flags = POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        switch isolation {
        case .processGroup:
            flags |= POSIX_SPAWN_SETPGROUP
            // 0 を指定すると子自身が新しいプロセスグループのリーダーになる。
            posix_spawnattr_setpgroup(&attributes, 0)
        case .session:
            // 対話シェルが親の制御TTYをバックグラウンドから操作して
            // SIGTTOU で停止しないよう、新しいセッションとして起動する。
            flags |= POSIX_SPAWN_SETSID
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let executablePath = command.executableURL.path
        let argv = [executablePath] + command.arguments
        let envp = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        var pid: pid_t = 0
        let spawnResult = withCStringArray(argv) { cArgv in
            withCStringArray(envp) { cEnvp in
                posix_spawn(&pid, executablePath, &fileActions, &attributes, cArgv, cEnvp)
            }
        }

        if case .pipes = output {
            // 書き込み側は子だけが持つ。親側を閉じないと EOF を検知できない。
            close(stdoutPipe[1])
            close(stderrPipe[1])
        }

        guard spawnResult == 0 else {
            if case .pipes = output {
                closeAll([stdoutPipe[0], stderrPipe[0]])
            }
            throw ProcessSpawnError.spawnFailed(errno: spawnResult, executable: executablePath)
        }

        switch output {
        case .pipes:
            return SpawnedProcess(
                pid: pid,
                processGroupID: pid,
                stdoutFD: stdoutPipe[0],
                stderrFD: stderrPipe[0]
            )
        case .files:
            return SpawnedProcess(pid: pid, processGroupID: pid, stdoutFD: nil, stderrFD: nil)
        }
    }

    private static func prepareLogFile(at url: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw ProcessSpawnError.logFileUnavailable(path: url.path)
        }
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }
}

func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
