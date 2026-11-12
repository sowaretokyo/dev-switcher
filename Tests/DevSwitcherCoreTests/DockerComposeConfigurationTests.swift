import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("Compose 設定・名前・コマンド")
struct DockerComposeConfigurationTests {
    private func file(_ directory: URL, _ text: String) throws -> URL { try file(directory, "compose.yaml", text) }
    private func file(_ directory: URL, _ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    @Test("既定ファイルと同じ系統の override を優先順で確定する")
    func fileSelection() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try file(directory, "docker-compose.yaml", "services: {}")
        _ = try file(directory, "compose.yml", "services: {}")
        _ = try file(directory, "compose.override.yml", "services: {}")
        _ = try file(directory, "docker-compose.override.yaml", "services: {}")
        #expect(try ComposeFileLocator.locate(files: nil, workingDirectory: directory).map(\.lastPathComponent) == ["compose.yml", "compose.override.yml"])
        #expect(try ComposeFileLocator.locate(files: ["docker-compose.yaml", "compose.yml"], workingDirectory: directory).map(\.lastPathComponent) == ["docker-compose.yaml", "compose.yml"])
    }
    @Test("親ディレクトリを探索せず、不正パスや空配列を拒否する")
    func invalidFiles() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try file(directory, "services: {}")
        let child = directory.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        #expect(throws: ComposeConfigurationError.self) { try ComposeFileLocator.locate(files: nil, workingDirectory: child) }
        for paths in [[], [""], ["/tmp/compose.yaml"], ["~/compose.yaml"], ["missing.yaml"], [".env"], [".env.dev"]] {
            #expect(throws: ComposeConfigurationError.self) { try ComposeFileLocator.locate(files: paths, workingDirectory: directory) }
        }
        #expect(try ComposeFileLocator.locate(files: ["../compose.yaml"], workingDirectory: child).count == 1)
    }
    @Test("トップレベル name の引用符・コメントとネストを区別する", arguments: ["name: shop-web", "name: 'shop-web' # note", "\"name\": \"shop-web\"", "services:\n  name: nested\nname: shop-web\n", "# name: ignored\nname: shop-web"])
    func simpleNames(_ text: String) throws { #expect(try ComposeProjectNameReader.read(text) == "shop-web") }
    @Test("曖昧な名前を推測しない", arguments: ["name: ${APP}", "name: 'Shop'", "name: \"shop\\n\"", "name: shop\nname: shop", "name: [shop]", "name:", "name: shop # x\nname: other", "{name: shop}"])
    func invalidNames(_ text: String) { #expect(throws: ComposeConfigurationError.self) { try ComposeProjectNameReader.read(text) } }
    @Test("明示名・複数ファイルの name・ディレクトリ名の順に解決する")
    func namePrecedence() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try file(directory, "name: base\nservices: {}")
        let second = try file(directory, "extra.yaml", "name: other\nservices: {}")
        #expect(throws: ComposeConfigurationError.self) { try ComposeProjectNameReader.resolve(explicit: nil, files: [first, second]) }
        #expect(try ComposeProjectNameReader.resolve(explicit: "explicit", files: [first, second]).rawValue == "explicit")
        #expect(throws: ComposeConfigurationError.self) { try ComposeProjectNameReader.resolve(explicit: "UPPER", files: [first]) }
        _ = try file(directory, "services:\n  name: nested")
        #expect(try ComposeProjectNameReader.resolve(explicit: nil, files: [first]).rawValue == directory.lastPathComponent.lowercased())
        #expect(try ComposeProjectName.fromDirectory(URL(fileURLWithPath: "/tmp/My.Web 日本語/")).rawValue == "myweb")
    }
    @Test("追加引数の許可リスト", arguments: [["db", "worker_1"], ["--build", "--wait", "--pull=always", "--wait-timeout=3"], ["--pull", "missing", "--wait-timeout", "1"], ["--no-deps", "--quiet-pull", "--force-recreate"]])
    func allowedArguments(_ args: [String]) throws { try ComposeCommandRules.validateUpArguments(args) }
    @Test("追加引数の未知値・破壊的操作を拒否する", arguments: [["-dV"], ["--remove-orphans"], ["--no-start"], ["--pull"], ["--pull", "bad"], ["--wait-timeout=0"], ["--wait-timeout", "-1"], ["--wait-timeout=+1"], ["--watch"], ["--project-name=x"], ["--detach"], ["--pull==always"], ["--attach"], ["--renew-anon-volumes"]])
    func forbiddenArguments(_ args: [String]) { #expect(throws: ComposeConfigurationError.self) { try ComposeCommandRules.validateUpArguments(args) } }
    @Test("全コマンドのプロジェクト・ファイルを固定し、停止だけ全 profile を指定する")
    func commandScope() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(directory, "services: {}")
        let config = try DockerComposeStackConfiguration(projectName: "shop", profiles: ["dev", "test"], upArguments: ["--build", "db"]).resolve(workingDirectory: directory)
        let prefix = ["compose", "-p", "shop", "-f", url.path, "--profile", "dev", "--profile", "test"]
        #expect(config.startCommand.arguments == prefix + ["up", "-d", "--build", "db"])
        #expect(config.observationCommand.arguments == prefix + ["ps", "--all", "--format", "json"])
        #expect(config.stopCommand.arguments == ["compose", "-p", "shop", "-f", url.path, "--profile", "*", "stop"])
        for command in [config.startCommand, config.observationCommand, config.stopCommand] { try ComposeCommandRules.validateCommand(command) }
        for suffix in [["down"], ["rm"], ["kill"], ["up", "-dV"], ["up", "-d", "--remove-orphans"]] {
            let command = CommandSpec(executable: "docker", arguments: prefix + suffix, workingDirectory: directory)
            #expect(throws: ComposeConfigurationError.self) { try ComposeCommandRules.validateCommand(command) }
        }
    }

    @Test("設定した profile によらず全 profile を停止し、限定した停止を実行境界で拒否する")
    func stopAlwaysIncludesEveryProfile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(directory, "services: {}")
        let choices: [[String]?] = [nil, ["dev"], ["dev", "test"], ["*"]]
        for profiles in choices {
            let configuration = try DockerComposeStackConfiguration(projectName: "shop", profiles: profiles)
                .resolve(workingDirectory: directory)
            #expect(configuration.stopCommand.arguments == ["compose", "-p", "shop", "-f", url.path, "--profile", "*", "stop"])
            #expect(configuration.fingerprint.profiles == (profiles ?? []))
            try ComposeCommandRules.validateCommand(configuration.stopCommand)
        }
        for profiles in [[], ["dev"], ["*", "dev"]] {
            let prefix = ["compose", "-p", "shop", "-f", url.path]
            let command = CommandSpec(executable: "docker", arguments: prefix + profiles.flatMap { ["--profile", $0] } + ["stop"], workingDirectory: directory)
            #expect(throws: ComposeConfigurationError.self) { try ComposeCommandRules.validateCommand(command) }
        }
    }
}
