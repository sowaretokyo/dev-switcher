import Foundation

/// Supabase CLIの実行結果。終了コードと出力を分けて保持する。
public struct SupabaseCommandResult: Equatable, Sendable {
    public let status: ExitStatus
    public let standardOutput: String
    public let standardError: String

    public init(status: ExitStatus, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var isSuccess: Bool { status.isSuccess }

    public var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Supabase CLIの実行だけを差し替え可能にする。
public protocol SupabaseCommandRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> SupabaseCommandResult
}

public enum SupabaseCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case forbiddenOption(command: String, option: String)
    case unresolvable(command: String, reason: String)

    public var description: String {
        switch self {
        case let .forbiddenOption(command, option):
            "`\(option)` は実行できません（\(command)）。"
        case let .unresolvable(command, reason):
            "コマンド「\(command)」を実行できません。\n\(reason)"
        }
    }
}

/// 実プロセスでSupabase CLIを実行する。
///
/// `--all`と`--no-backup`は最後の実行境界でも拒否する。コマンド生成側の変更が
/// 漏れても、複数プロジェクトやバックアップを巻き込む停止が実行されないようにする。
public struct SupabaseProcessCommandRunner: SupabaseCommandRunning {
    public typealias EnvironmentProvider = @Sendable () async throws -> ShellEnvironment

    private let environmentProvider: EnvironmentProvider
    private let timeout: Duration

    public init(
        environmentProvider: @escaping EnvironmentProvider,
        timeout: Duration = .seconds(300)
    ) {
        self.environmentProvider = environmentProvider
        self.timeout = timeout
    }

    public func run(_ command: CommandSpec) async throws -> SupabaseCommandResult {
        if let forbidden = ServiceDefinition.forbiddenStopOptions.first(where: {
            command.arguments.contains($0)
        }) {
            throw SupabaseCommandError.forbiddenOption(
                command: command.displayCommandLine,
                option: forbidden
            )
        }

        let environment = try await environmentProvider()
        // 対象はCommandSpecのcwdと明示的な--workdirだけで決める。
        // ログインシェル由来の値で、検証済みの設定とは別のスタックを操作させない。
        var variables = environment.variables
        variables.removeValue(forKey: "SUPABASE_WORKDIR")
        let resolved: ResolvedCommand
        do {
            resolved = try ExecutableResolver.resolve(command, searchPath: environment.searchPath)
        } catch {
            throw SupabaseCommandError.unresolvable(
                command: command.displayCommandLine,
                reason: "\(error)"
            )
        }

        let output = try await CommandOutput.capture(
            executable: resolved.executableURL,
            arguments: resolved.arguments,
            environment: variables,
            workingDirectory: resolved.workingDirectory,
            timeout: timeout
        )
        return SupabaseCommandResult(
            status: output.status,
            standardOutput: output.standardOutputText,
            standardError: output.standardErrorText
        )
    }
}
