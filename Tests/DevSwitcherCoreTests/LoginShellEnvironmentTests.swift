import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("ログインシェル環境の取得")
struct LoginShellEnvironmentTests {
    @Test("NUL 区切りの出力を解析する")
    func parsesNULSeparatedOutput() throws {
        let payload = Data("PATH=/usr/bin:/bin\0HOME=/Users/example\0LANG=ja_JP.UTF-8\0".utf8)
        let variables = try LoginShellEnvironment.parse(payload)

        #expect(variables["PATH"] == "/usr/bin:/bin")
        #expect(variables["HOME"] == "/Users/example")
        #expect(variables["LANG"] == "ja_JP.UTF-8")
    }

    @Test("値に = を含む変数を壊さない")
    func keepsEqualSignsInValue() throws {
        let payload = Data("FOO=a=b=c\0".utf8)
        let variables = try LoginShellEnvironment.parse(payload)
        #expect(variables["FOO"] == "a=b=c")
    }

    @Test("シェル設定が混ぜ込んだ出力を黙って受け入れない")
    func rejectsUnexpectedOutput() {
        let payload = Data("welcome message\nPATH=/usr/bin\0HOME=/Users/example\0".utf8)
        #expect(
            throws: LoginShellEnvironmentError.unexpectedOutput(
                preview: "welcome message\nPATH=/usr/bin"
            )
        ) {
            _ = try LoginShellEnvironment.parse(payload)
        }
    }

    @Test("出力が空なら失敗させる")
    func rejectsEmptyOutput() {
        #expect(throws: LoginShellEnvironmentError.emptyOutput) {
            _ = try LoginShellEnvironment.parse(Data())
        }
    }

    @Test("固定コマンドはシェル文字列の連結を含まない")
    func fixedCommandShape() {
        #expect(LoginShellEnvironment.arguments == ["-lic", "/usr/bin/env -0"])
    }

    @Test("SHELL が実行可能な絶対パスならそれを使う")
    func resolvesShellFromEnvironment() throws {
        let url = try LoginShellEnvironment.resolveShell(environment: ["SHELL": "/bin/sh"])
        #expect(url.path == "/bin/sh")
    }

    @Test("SHELL が未設定または空なら shellNotSet", arguments: [["PATH": "/usr/bin"], ["SHELL": ""]])
    func rejectsMissingOrEmptyShell(environment: [String: String]) {
        #expect(throws: LoginShellEnvironmentError.shellNotSet) {
            try LoginShellEnvironment.resolveShell(environment: environment)
        }
    }

    @Test(
        "SHELL が相対パス・存在しないパス・ディレクトリ・csh 系なら、対応するエラーに値と文言を含める",
        arguments: [
            ("zsh", LoginShellEnvironmentError.shellNotAbsolutePath("zsh")),
            (
                "/nonexistent/devswitcher-shell",
                LoginShellEnvironmentError.shellNotFound("/nonexistent/devswitcher-shell")
            ),
            ("/usr/bin", LoginShellEnvironmentError.shellNotExecutable("/usr/bin")),
            ("/bin/tcsh", LoginShellEnvironmentError.shellUnsupported("/bin/tcsh")),
            ("/bin/csh", LoginShellEnvironmentError.shellUnsupported("/bin/csh")),
        ]
    )
    func rejectsInvalidShell(shell: String, expected: LoginShellEnvironmentError) {
        let thrown = #expect(throws: expected) {
            try LoginShellEnvironment.resolveShell(environment: ["SHELL": shell])
        }
        #expect(thrown?.description.contains(shell) == true)
    }

    @Test("SHELL が実行権限のないファイルなら shellNotExecutable")
    func rejectsNonExecutableShell() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-executable")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(throws: LoginShellEnvironmentError.shellNotExecutable(file.path)) {
            try LoginShellEnvironment.resolveShell(environment: ["SHELL": file.path])
        }
    }

    @Test("bash・zsh・sh は従来どおり解決できる", arguments: ["/bin/bash", "/bin/zsh", "/bin/sh"])
    func resolvesSupportedShells(path: String) throws {
        let url = try LoginShellEnvironment.resolveShell(environment: ["SHELL": path])
        #expect(url.path == path)
    }

    @Test("load は csh 系をコマンド実行前に shellUnsupported で失敗させる")
    func loadFailsForCshFamilyBeforeRunning() async {
        await #expect(throws: LoginShellEnvironmentError.shellUnsupported("/bin/tcsh")) {
            _ = try await LoginShellEnvironment.load(environment: ["SHELL": "/bin/tcsh"])
        }
    }

    @Test("画面表示用の説明は解決したシェルの実パスを含む")
    func commandDescriptionContainsResolvedPath() throws {
        let description = try LoginShellEnvironment.commandDescription(environment: ["SHELL": "/bin/sh"])
        #expect(description == "/bin/sh -lic /usr/bin/env -0")
        #expect(throws: LoginShellEnvironmentError.shellNotSet) {
            _ = try LoginShellEnvironment.commandDescription(environment: [:])
        }
    }

    @Test("load は SHELL の不備を既定シェルへ倒さず失敗させる")
    func loadFailsWithoutShell() async {
        await #expect(throws: LoginShellEnvironmentError.shellNotSet) {
            _ = try await LoginShellEnvironment.load(environment: ["PATH": "/usr/bin"])
        }
    }

    @Test("PATHが無い環境は生成できない")
    func shellEnvironmentRequiresNonEmptyPATH() {
        #expect(throws: LoginShellEnvironmentError.missingPATH) {
            _ = try ShellEnvironment(variables: ["HOME": "/Users/example"])
        }
        #expect(throws: LoginShellEnvironmentError.missingPATH) {
            _ = try ShellEnvironment(variables: ["PATH": ""])
        }
    }

    @Test("実機のログインシェルから PATH を取得できる")
    func loadsRealEnvironment() async throws {
        let environment = try await LoginShellEnvironment.load()
        #expect(!environment.path.isEmpty)
        #expect(!environment.searchPath.isEmpty)
    }
}
