import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("既存定義の候補検出")
struct DefinitionDiscoveryTests {
    private func write(_ name: String, _ text: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("scripts の本文を保持し、登録コマンドは manager run と名前から作る")
    func scripts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("package.json", #"{"scripts":{"worker":"node worker.js","dev":"echo hello && touch SHOULD_NOT_EXIST","predev":"echo prepare"},"packageManager":"pnpm@10.0.0","dependencies":{"ignored":"1"}}"#, in: directory)
        try write("pnpm-lock.yaml", "lockfileVersion: 9", in: directory)
        let result = try DefinitionDiscovery.scan(directory: directory)
        #expect(result.issues.isEmpty)
        #expect(result.scripts.map(\.name) == ["dev", "predev", "worker"])
        #expect(result.scripts[0].body == "echo hello && touch SHOULD_NOT_EXIST")
        #expect(result.suggestedManager == .pnpm)
        #expect(result.declaredPackageManager == "pnpm@10.0.0")
        for manager in ScriptPackageManager.allCases {
            let command = manager.command(script: "dev:web", directory: directory)
            #expect(command.executable == manager.rawValue)
            #expect(command.arguments == ["run", "dev:web"])
            #expect(command.workingDirectory == directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test("lockfile の未検出・競合では manager を補完しない")
    func managerConflict() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try DefinitionDiscovery.scan(directory: directory).suggestedManager == nil)
        try write("package-lock.json", "not parsed", in: directory)
        try write("npm-shrinkwrap.json", "not parsed", in: directory)
        #expect(try DefinitionDiscovery.scan(directory: directory).suggestedManager == .npm)
        try write("yarn.lock", "not parsed", in: directory)
        let result = try DefinitionDiscovery.scan(directory: directory)
        #expect(result.managers.map(\.manager) == [.npm, .yarn])
        #expect(result.suggestedManager == nil)
    }

    @Test("不正な lockfile を見落として別の manager を選ばない")
    func invalidLockfile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pnpm-lock.yaml"), withIntermediateDirectories: false)
        let result = try DefinitionDiscovery.scan(directory: directory)
        #expect(!result.issues.isEmpty)
        #expect(result.suggestedManager == nil)
        try write("yarn.lock", "", in: directory)
        #expect(try DefinitionDiscovery.scan(directory: directory).suggestedManager == nil)
    }

    @Test("scripts が任意であることと、値が壊れていることを区別する",
          arguments: ["{", #"{"scripts":null}"#, #"{"scripts":{"dev":3}}"#,
                      #"{"scripts":{"dev":""}}"#, #"{"scripts":{"-x":"node app.js"}}"#])
    func invalidPackage(_ source: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("package.json", source, in: directory)
        try write("compose.yaml", "name: shop\nservices: {}", in: directory)
        let result = try DefinitionDiscovery.scan(directory: directory)
        #expect(result.scripts.isEmpty)
        #expect(result.issues.count == 1)
        #expect(result.compose?.projectName == "shop")
    }

    @Test("親・子を探索せず scripts のない package.json は候補0件にする")
    func directChildrenOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("package.json", #"{"scripts":{"dev":"node app.js"}}"#, in: directory)
        try write("compose.yaml", "services: {}", in: directory)
        let child = directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try write("package.json", #"{"name":"child"}"#, in: child)
        let result = try DefinitionDiscovery.scan(directory: child)
        #expect(result.scripts.isEmpty && result.compose == nil && result.issues.isEmpty)
        #expect(try DefinitionDiscovery.scan(directory: directory).scripts.count == 1)
        #expect(throws: (any Error).self) {
            try DefinitionDiscovery.scan(directory: child.appendingPathComponent("missing"))
        }
    }

    @Test("Compose は基本と override を1スタックとして対象を明示する")
    func composeFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("compose.yml", "name: shop\nservices: {}", in: directory)
        try write("compose.override.yaml", "services: {}", in: directory)
        try write("docker-compose.yaml", "name: ignored\nservices: {}", in: directory)
        let result = try DefinitionDiscovery.scan(directory: directory)
        let compose = try #require(result.compose)
        #expect(compose.files == ["compose.yml", "compose.override.yaml"])
        #expect(compose.configuration == .init(projectName: "shop", files: compose.files))
        #expect(result.issues.isEmpty)
        try write("compose.override.yaml", "name: different\nservices: {}", in: directory)
        let changed = try DefinitionDiscovery.scan(directory: directory)
        #expect(changed.compose == nil)
        #expect(changed.issues.count == 1)
    }

    @Test("環境設定への symlink は内容を読まず拒否する", arguments: ["package.json", "compose.yaml"])
    func refusesEnvironmentFile(_ name: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 読むと JSON/YAML エラーになる値でも、読み取り前のパス検証で拒否する。
        try write(".env", "not a definition", in: directory)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(name).path,
                                                   withDestinationPath: ".env")
        let result = try DefinitionDiscovery.scan(directory: directory)
        #expect(result.scripts.isEmpty && result.compose == nil)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].contains("環境設定ファイル"))
    }

    @Test("表示内容が同じでも出典の変更を検知する")
    func sourceChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("package.json", #"{"scripts":{"dev":"node app.js"}}"#, in: directory)
        try write("compose.yaml", "name: shop\nservices: {}", in: directory)
        let original = try DefinitionDiscovery.scan(directory: directory)
        try write("package.json", #"{"scripts":{"dev":"node app.js"},"config":{"port":4000}}"#, in: directory)
        #expect(try DefinitionDiscovery.scan(directory: directory) != original)
        let updated = try DefinitionDiscovery.scan(directory: directory)
        try write("compose.yaml", "name: shop\nservices: {}\n# changed", in: directory)
        #expect(try DefinitionDiscovery.scan(directory: directory) != updated)
    }
}
