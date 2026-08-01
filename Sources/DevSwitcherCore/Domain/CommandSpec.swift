import Foundation

/// 利用者の入力をシェル文字列へ連結しないため、実行ファイルと引数を分けて保持する。
/// 実行ファイルを解決できない場合も、既定コマンドへ差し替えず起動を止める。
public struct CommandSpec: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL

    public init(executable: String, arguments: [String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// 表示文字列を実行へ再利用しない。
    public var displayCommandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// 未解決の設定値を起動処理へ渡さないため、`CommandSpec` と型を分ける。
public struct ResolvedCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL

    public init(executableURL: URL, arguments: [String], workingDirectory: URL) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}
