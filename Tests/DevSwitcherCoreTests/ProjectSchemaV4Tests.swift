import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("設定 v4")
struct ProjectSchemaV4Tests {
    private func project(_ directory: URL) -> ProjectDefinition {
        let process = DevSwitcherCore.ServiceDefinition(name: "Worker", tag: "独自タグ", ports: [], start: CommandSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: directory), enabledByDefault: true, failurePolicy: .block)
        return ProjectDefinition(name: "Shop", color: .blue, workingDirectories: [.init(name: "App", directory: directory, serviceIDs: [process.id])], services: [process])
    }
    @Test("tag は表示だけに使い、v4 の往復保存で全設定を保持する")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = project(directory)
        let data = try ProjectsDocument(projects: [value]).jsonData()
        #expect(try ProjectStore.projectsForImport(data, path: "memory", existingProjects: []) == [value])
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 4"))
        #expect(ProjectValidator.validate(value).isEmpty)
    }
    @Test("すべての階層で未知キーと任意値の null を拒否する", arguments: ["document", "project", "directory", "service", "command", "tagNull"])
    func strictKeys(_ target: String) throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var document = try #require(JSONSerialization.jsonObject(with: ProjectsDocument(projects: [project(directory)]).jsonData()) as? [String: Any])
        var project = try #require((document["projects"] as? [[String: Any]])?.first)
        var service = try #require((project["services"] as? [[String: Any]])?.first)
        switch target {
        case "document": document["typo"] = true
        case "project": project["typo"] = true
        case "directory":
            var dirs = try #require(project["workingDirectories"] as? [[String: Any]]); dirs[0]["typo"] = true; project["workingDirectories"] = dirs
        case "service": service["typo"] = true
        case "command": var command = try #require(service["start"] as? [String: Any]); command["typo"] = true; service["start"] = command
        case "tagNull": service["tag"] = NSNull()
        default: Issue.record("未知のテスト入力")
        }
        if ["service", "command", "tagNull"].contains(target) { project["services"] = [service] }
        document["projects"] = [project]
        #expect(throws: ProjectStoreError.self) { try ProjectStore.decode(JSONSerialization.data(withJSONObject: document), path: "memory") }
    }
    @Test("v3 の ID・プロセス順・停止順・起動対象を保持し、順序変更を通知する")
    func migrateV3() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let web = makeService(name: "Web", workingDirectory: directory)
        let stack = makeSupabaseService(workingDirectory: directory)
        let worker = makeService(name: "Worker", kind: .worker, ports: [], workingDirectory: directory)
        let units = [web, stack, worker]
        let legacy = try units.map { unit in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSchemaV3.Service(id: unit.id, name: unit.name, kind: unit.kind, ports: unit.ports, start: unit.start, stop: unit.stop, enabledByDefault: unit.enabledByDefault, failurePolicy: unit.failurePolicy)))
        }
        let id = UUID(), directoryID = UUID()
        let object: [String: Any] = ["schemaVersion": 3, "projects": [["id": id.uuidString, "name": "Shop", "color": "blue",
            "workingDirectories": [["id": directoryID.uuidString, "name": "App", "directory": directory.absoluteString, "serviceIDs": units.map { $0.id.uuidString }]],
            "services": legacy, "stopOrder": [worker.id, stack.id, web.id].map(\.uuidString), "enabledNow": [stack.id.uuidString: false, worker.id.uuidString: true]]]]
        let migrated = try #require(ProjectStore.decode(JSONSerialization.data(withJSONObject: object), path: "memory").first)
        #expect(migrated.id == id)
        #expect(migrated.services.map(\.id) == [web.id, worker.id])
        #expect(migrated.managedStacks.map(\.id) == [stack.id])
        #expect(migrated.workingDirectories[0].stackIDs == [stack.id])
        #expect(migrated.stopOrder == [worker.id, web.id])
        #expect(!migrated.isEnabledNow(stack.id))
        #expect(migrated.migrationNotice != nil)
        #expect(migrated.launchUnits.map(\.id) == [stack.id, web.id, worker.id])
        #expect(migrated.shutdownUnits.map(\.id) == [worker.id, web.id, stack.id])
        #expect(try ProjectStore.decode(ProjectsDocument(projects: [migrated]).jsonData(), path: "memory").first?.migrationNotice == nil)
    }
    @Test("同じ名前の Compose スタックは同じ環境内でも重複として拒否する")
    func duplicateComposeIdentity() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let first = ManagedStackDefinition(id: UUID(), name: "One", configuration: .dockerCompose(.init(projectName: "same")), ports: [], enabledByDefault: true, failurePolicy: .block)
        var second = first; second.id = UUID(); second.name = "Two"
        let value = ProjectDefinition(name: "Shop", color: .blue, workingDirectories: [.init(name: "App", directory: directory, serviceIDs: [], stackIDs: [first.id, second.id])], services: [DevSwitcherCore.ServiceDefinition](), managedStacks: [first, second])
        #expect(ProjectValidator.structuralErrors(value).isEmpty)
        #expect(ProjectValidator.managedStackIdentityErrors(value, existingProjects: []).contains { if case .duplicateManagedStackIdentity = $0 { true } else { false } })
    }
}

extension ProjectSchemaV4Tests {
    @Test("通常プロセスの Supabase 起動を拒否し、曖昧な呼び出しと Docker は警告に分ける")
    func processCommandClassification() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, [String], ProcessCommandClassification.SupabaseStart)] = [
            ("supabase", ["start"], .certain),
            ("supabase", ["--profile", "dev", "start"], .certain),
            ("supabase", ["--profile", "start"], .none),
            ("pnpm", ["exec", "supabase", "start"], .certain),
            ("pnpm", ["supabase", "start"], .certain),
            ("npx", ["-y", "supabase", "start"], .possible),
            ("pnpm", ["--filter", "supabase", "start"], .possible),
            ("pnpm", ["--filter=api", "supabase", "start"], .possible),
            ("docker", ["compose", "up"], .none),
        ]
        for (executable, arguments, expected) in cases {
            let command = CommandSpec(executable: executable, arguments: arguments, workingDirectory: directory)
            #expect(ProcessCommandClassification.supabaseStart(command) == expected)
            var value = project(directory)
            value.services[0].start = command
            let errors = ProjectValidator.structuralErrors(value)
            #expect(errors.contains { if case .processUsesManagedStackCommand = $0 { true } else { false } } == (expected == .certain))
            #expect(!ProjectValidator.warnings(value).isEmpty == (expected == .possible || executable == "docker"))
        }
    }
    @Test("Supabase の CLI 作業ディレクトリと ID を読むディレクトリの不一致を拒否する")
    func supabaseDirectoryMustMatch() throws {
        let directory = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SupabaseStackConfiguration(start: CommandSpec(executable: "supabase", arguments: ["start"], workingDirectory: directory.appendingPathComponent("other")))
        #expect(configuration.structuralIssues(workingDirectory: directory) == [.workingDirectoryMismatch])
        #expect(throws: ManagedStackConfigurationError.self) { try configuration.resolve(workingDirectory: directory) }
    }
}
