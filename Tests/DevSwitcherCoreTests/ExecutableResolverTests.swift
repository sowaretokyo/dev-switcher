import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("実行ファイルの解決")
struct ExecutableResolverTests {
    @Test("PATH からコマンド名を解決する")
    func resolvesFromSearchPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = CommandSpec(executable: "echo", arguments: ["hi"], workingDirectory: directory)
        let resolved = try ExecutableResolver.resolve(command, searchPath: ["/usr/bin", "/bin"])

        #expect(resolved.executableURL.path == "/bin/echo")
        #expect(resolved.arguments == ["hi"])
    }

    @Test("絶対パスをそのまま使う")
    func resolvesAbsolutePath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = CommandSpec(executable: "/bin/echo", arguments: [], workingDirectory: directory)
        let resolved = try ExecutableResolver.resolve(command, searchPath: [])
        #expect(resolved.executableURL.path == "/bin/echo")
    }

    @Test("見つからないコマンドは既定値へ倒さず失敗させる")
    func missingCommandFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = CommandSpec(
            executable: "definitely-not-installed-command",
            arguments: [],
            workingDirectory: directory
        )
        #expect(throws: ExecutableResolutionError.self) {
            _ = try ExecutableResolver.resolve(command, searchPath: ["/usr/bin", "/bin"])
        }
    }

    @Test("実行権限のないファイルを拒否する")
    func nonExecutableFileFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("not-executable.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)

        let command = CommandSpec(executable: script.path, arguments: [], workingDirectory: directory)
        #expect(throws: ExecutableResolutionError.self) {
            _ = try ExecutableResolver.resolve(command, searchPath: [])
        }
    }

    @Test("作業ディレクトリが無ければ起動前に失敗させる")
    func missingWorkingDirectoryFails() throws {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.removeItem(at: directory)

        let command = CommandSpec(executable: "/bin/echo", arguments: [], workingDirectory: directory)
        #expect(throws: ExecutableResolutionError.self) {
            _ = try ExecutableResolver.resolve(command, searchPath: [])
        }
    }
}
