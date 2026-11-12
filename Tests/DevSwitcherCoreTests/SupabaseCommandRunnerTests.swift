import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("Supabase CLIの実行環境")
struct SupabaseCommandRunnerTests {
    @Test("周辺環境でworkdirを変えず、指定した引数・cwd・他の環境値を維持する",
          arguments: [["start"], ["status", "--workdir", "/explicit/path"], ["stop", "--project-id", "demo"]])
    func ignoresAmbientWorkdir(arguments: [String]) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("supabase")
        try Data("""
            #!/bin/sh
            test "${SUPABASE_WORKDIR+x}" != x || exit 42
            printf '%s\\n' "$TEST_KEEP" "$PWD" "$@"
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = try ShellEnvironment(variables: [
            "PATH": directory.path + ":/usr/bin:/bin",
            "SUPABASE_WORKDIR": "/unexpected/project",
            "TEST_KEEP": "preserved",
        ])
        let runner = ManagedStackProcessCommandRunner(environmentProvider: { environment })
        let result = try await runner.run(CommandSpec(
            executable: "supabase", arguments: arguments, workingDirectory: directory
        ), policy: SupabaseStackDriver.commandPolicy)

        #expect(result.isSuccess)
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        try #require(lines.count == arguments.count + 2)
        #expect(lines[0] == "preserved")
        #expect(URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath()
            == directory.resolvingSymlinksInPath())
        #expect(Array(lines.dropFirst(2)) == arguments)
    }
}
