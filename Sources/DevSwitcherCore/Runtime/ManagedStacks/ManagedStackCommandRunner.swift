import Foundation

/// 管理対象スタックのコマンドの実行結果。終了コードと出力を分けて保持する。
public struct ManagedStackCommandResult: Equatable, Sendable {
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

/// 種類ごとに、最後の実行境界で守る規則。
///
/// コマンドの構築側でも同じ規則を守るが、構築側の変更が漏れても危険な操作が
/// 実行されないよう、実行器でもう一度拒否・除去する。
public struct ManagedStackCommandPolicy: Equatable, Sendable {
    /// 引数トークンと完全一致したら実行しない引数。
    public let forbiddenArguments: Set<String>
    /// 実行環境から除く環境変数。対象を設定とは別の値で決めさせないため。
    public let removedEnvironmentKeys: Set<String>

    public init(forbiddenArguments: Set<String>, removedEnvironmentKeys: Set<String>) {
        self.forbiddenArguments = forbiddenArguments
        self.removedEnvironmentKeys = removedEnvironmentKeys
    }
}

/// 種類ごとのコマンド実行を差し替え可能にする。
public protocol ManagedStackCommandRunning: Sendable {
    func run(_ command: CommandSpec, policy: ManagedStackCommandPolicy) async throws -> ManagedStackCommandResult
}

public enum ManagedStackCommandError: Error, Equatable, Sendable, CustomStringConvertible {
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

/// 実プロセスでコマンドを実行する。
///
/// `policy`の禁止引数を引数トークンの完全一致で拒否し、指定された環境変数を除いてから実行する。
public struct ManagedStackProcessCommandRunner: ManagedStackCommandRunning {
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

    public func run(
        _ command: CommandSpec,
        policy: ManagedStackCommandPolicy
    ) async throws -> ManagedStackCommandResult {
        if let forbidden = policy.forbiddenArguments.sorted().first(where: {
            command.arguments.contains($0)
        }) {
            throw ManagedStackCommandError.forbiddenOption(
                command: command.displayCommandLine,
                option: forbidden
            )
        }

        let environment = try await environmentProvider()
        // 対象は CommandSpec の cwd と明示的な引数だけで決める。
        // ログインシェル由来の値で、検証済みの設定とは別のスタックを操作させない。
        var variables = environment.variables
        for key in policy.removedEnvironmentKeys {
            variables.removeValue(forKey: key)
        }
        let resolved: ResolvedCommand
        do {
            resolved = try ExecutableResolver.resolve(command, searchPath: environment.searchPath)
        } catch {
            throw ManagedStackCommandError.unresolvable(
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
        return ManagedStackCommandResult(
            status: output.status,
            standardOutput: output.standardOutputText,
            standardError: output.standardErrorText
        )
    }
}
