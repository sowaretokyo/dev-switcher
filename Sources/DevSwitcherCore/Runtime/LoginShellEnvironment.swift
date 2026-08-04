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

public enum LoginShellEnvironmentError: Error, Sendable, CustomStringConvertible {
    case launchFailed(String)
    case timedOut(seconds: Double)
    case commandFailed(status: ExitStatus, standardError: String)
    case unexpectedOutput(preview: String)
    case emptyOutput
    case missingPATH

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
        }
    }
}

/// GUIアプリのPATHはターミナルと異なるため、固定コマンドでログインシェルから取得する。
/// 利用者入力はシェルへ埋め込まず、取得失敗も最小PATHへフォールバックしない。
public enum LoginShellEnvironment {
    public static let executable = URL(fileURLWithPath: "/bin/zsh")
    public static let arguments = ["-lic", "/usr/bin/env -0"]

    public static func load(timeout: Duration = .seconds(20)) async throws -> ShellEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let captured: CapturedOutput
        do {
            captured = try await CommandOutput.capture(
                executable: executable,
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
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
