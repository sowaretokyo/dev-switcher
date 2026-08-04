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
        #expect(throws: LoginShellEnvironmentError.self) {
            _ = try LoginShellEnvironment.parse(payload)
        }
    }

    @Test("出力が空なら失敗させる")
    func rejectsEmptyOutput() {
        #expect(throws: LoginShellEnvironmentError.self) {
            _ = try LoginShellEnvironment.parse(Data())
        }
    }

    @Test("固定コマンドはシェル文字列の連結を含まない")
    func fixedCommandShape() {
        #expect(LoginShellEnvironment.executable.path == "/bin/zsh")
        #expect(LoginShellEnvironment.arguments == ["-lic", "/usr/bin/env -0"])
    }

    @Test("PATHが無い環境は生成できない")
    func shellEnvironmentRequiresNonEmptyPATH() {
        #expect(throws: LoginShellEnvironmentError.self) {
            _ = try ShellEnvironment(variables: ["HOME": "/Users/example"])
        }
        #expect(throws: LoginShellEnvironmentError.self) {
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
