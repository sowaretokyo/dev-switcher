import Foundation

public struct ShellEnvironment: Equatable, Sendable {
    public let variables: [String: String]
    public let path: String

    public init(variables: [String: String]) throws {
        guard let path = variables["PATH"], !path.isEmpty else {
            throw LoginShellEnvironmentError.missingPATH
        }
        self.variables = variables
        self.path = path
    }

    public var searchPath: [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }
}

public enum LoginShellEnvironmentError: Error, Equatable, Sendable, CustomStringConvertible {
    case launchFailed(String)
    case timedOut(seconds: Double)
    case commandFailed(status: ExitStatus, standardError: String)
    case unexpectedOutput(preview: String)
    case emptyOutput
    case missingPATH
    case shellNotSet
    case shellNotAbsolutePath(String)
    case shellNotFound(String)
    case shellNotExecutable(String)
    case shellUnsupported(String)

    public var description: String {
        switch self {
        case let .launchFailed(reason):
            "ログインシェル環境の取得コマンドを起動できませんでした。\n\(reason)"
        case let .timedOut(seconds):
            "ログインシェル環境の取得が \(Int(seconds)) 秒以内に完了しませんでした。"
        case let .commandFailed(status, standardError):
            "ログインシェル環境の取得に失敗しました（\(status.description)）。\n\(standardError)"
        case let .unexpectedOutput(preview):
            "ログインシェルの出力に想定外の内容が含まれています。\n\(preview)"
        case .emptyOutput:
            "ログインシェルから環境変数を取得できませんでした（出力が空です）。"
        case .missingPATH:
            "ログインシェルの環境に PATH が含まれていません。"
        case .shellNotSet:
            "ログインシェルを特定できません。環境変数 SHELL が未設定または空です。"
        case let .shellNotAbsolutePath(value):
            "ログインシェルを特定できません。環境変数 SHELL が絶対パスではありません（\(value)）。"
        case let .shellNotFound(value):
            "ログインシェルを特定できません。環境変数 SHELL が指すパスが存在しません（\(value)）。"
        case let .shellNotExecutable(value):
            "ログインシェルを特定できません。環境変数 SHELL が指すパスはディレクトリか、実行権限がありません（\(value)）。"
        case let .shellUnsupported(value):
            "SHELL が示すシェル（\(value)）は csh 系のため対応していません。csh 系はログインシェルとしてコマンドを実行できません。SHELL を bash・zsh などに設定し、アプリを再起動してください。"
        }
    }
}

/// GUIアプリのPATHはターミナルと異なるため、利用者のログインシェル（環境変数 SHELL）から固定コマンドで取得する。
/// 利用者入力はシェルへ埋め込まず、SHELL の不備や取得失敗も既定シェル・最小PATHへフォールバックしない。
public enum LoginShellEnvironment {
    public static let arguments = ["-lic", "/usr/bin/env -0"]

    /// 画面表示用。`resolveShell` で解決した実パスを含む。解決できない場合は throw する。
    public static func commandDescription(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let shell = try resolveShell(environment: environment)
        return "\(shell.path) \(arguments.joined(separator: " "))"
    }

    public static func resolveShell(environment: [String: String]) throws -> URL {
        guard let value = environment["SHELL"], !value.isEmpty else {
            throw LoginShellEnvironmentError.shellNotSet
        }
        guard value.hasPrefix("/") else {
            throw LoginShellEnvironmentError.shellNotAbsolutePath(value)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) else {
            throw LoginShellEnvironmentError.shellNotFound(value)
        }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: value) else {
            throw LoginShellEnvironmentError.shellNotExecutable(value)
        }
        let url = URL(fileURLWithPath: value)
        // csh 系は `-lic` を拒否し、`-l` も単独指定しか許さないため、コマンドを実行できない。
        if unsupportedShellNames.contains(url.lastPathComponent) {
            throw LoginShellEnvironmentError.shellUnsupported(value)
        }
        return url
    }

    private static let unsupportedShellNames: Set<String> = ["csh", "tcsh"]

    public static func load(
        timeout: Duration = .seconds(20),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ShellEnvironment {
        let executable = try resolveShell(environment: environment)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let captured: CapturedOutput
        do {
            captured = try await CommandOutput.capture(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: home,
                timeout: timeout
            )
        } catch let error as CommandOutputError {
            if case let .timedOut(_, seconds) = error {
                throw LoginShellEnvironmentError.timedOut(seconds: seconds)
            }
            throw LoginShellEnvironmentError.launchFailed(error.description)
        } catch {
            throw LoginShellEnvironmentError.launchFailed(String(describing: error))
        }

        guard captured.status.isSuccess else {
            throw LoginShellEnvironmentError.commandFailed(
                status: captured.status,
                standardError: captured.standardErrorText
            )
        }

        let variables = try parse(captured.standardOutput)
        guard let path = variables["PATH"], !path.isEmpty else {
            throw LoginShellEnvironmentError.missingPATH
        }
        return try ShellEnvironment(variables: variables)
    }

    /// シェルの設定ファイルが標準出力へ何か書いていると先頭のエントリが壊れるため、
    /// キーの形が環境変数名として妥当かを検査し、妥当でなければ失敗させる。
    static func parse(_ data: Data) throws -> [String: String] {
        let entries = data
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }

        guard !entries.isEmpty else {
            throw LoginShellEnvironmentError.emptyOutput
        }

        var variables: [String: String] = [:]
        for entry in entries {
            guard let separatorIndex = entry.firstIndex(of: "="),
                  isValidVariableName(String(entry[entry.startIndex..<separatorIndex]))
            else {
                throw LoginShellEnvironmentError.unexpectedOutput(preview: String(entry.prefix(120)))
            }
            let name = String(entry[entry.startIndex..<separatorIndex])
            let value = String(entry[entry.index(after: separatorIndex)...])
            variables[name] = value
        }
        return variables
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
