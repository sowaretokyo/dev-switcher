import Foundation

public enum ExecutableResolutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case executableEmpty
    case notFoundInSearchPath(name: String, searchPath: [String])
    case notFound(path: String)
    case notExecutable(path: String)
    case workingDirectoryMissing(URL)

    public var description: String {
        switch self {
        case .executableEmpty:
            "実行ファイルが指定されていません。"
        case let .notFoundInSearchPath(name, searchPath):
            "コマンド「\(name)」がログインシェルの PATH に見つかりません。\nPATH: \(searchPath.joined(separator: ":"))"
        case let .notFound(path):
            "実行ファイルが見つかりません（\(path)）。"
        case let .notExecutable(path):
            "実行権限がありません（\(path)）。"
        case let .workingDirectoryMissing(url):
            "作業ディレクトリが存在しません（\(url.path)）。"
        }
    }
}

/// 意図しない実行ファイルへの切り替えを避けるため、解決できなければ代替値へ倒さない。
public enum ExecutableResolver {
    public static func resolve(
        _ command: CommandSpec,
        searchPath: [String]
    ) throws -> ResolvedCommand {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        let workingDirectoryExists = fileManager.fileExists(
            atPath: command.workingDirectory.path,
            isDirectory: &isDirectory
        )
        guard workingDirectoryExists, isDirectory.boolValue else {
            throw ExecutableResolutionError.workingDirectoryMissing(command.workingDirectory)
        }

        let executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            throw ExecutableResolutionError.executableEmpty
        }

        let executableURL: URL
        if executable.contains("/") {
            executableURL = executable.hasPrefix("/")
                ? URL(fileURLWithPath: executable)
                : command.workingDirectory.appendingPathComponent(executable)
            guard fileManager.fileExists(atPath: executableURL.path) else {
                throw ExecutableResolutionError.notFound(path: executableURL.path)
            }
            guard fileManager.isExecutableFile(atPath: executableURL.path) else {
                throw ExecutableResolutionError.notExecutable(path: executableURL.path)
            }
        } else {
            guard let found = search(executable, in: searchPath) else {
                throw ExecutableResolutionError.notFoundInSearchPath(
                    name: executable,
                    searchPath: searchPath
                )
            }
            executableURL = found
        }

        return ResolvedCommand(
            executableURL: executableURL,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory
        )
    }

    private static func search(_ name: String, in searchPath: [String]) -> URL? {
        let fileManager = FileManager.default
        for directory in searchPath where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }
}
