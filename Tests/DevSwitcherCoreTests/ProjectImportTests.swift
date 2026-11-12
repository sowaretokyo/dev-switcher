import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("JSON設定の取り込み")
struct ProjectImportTests {
    @Test("番号が異なっても同一プロセス内のポートID重複は取り込み・保存・読込で拒否する")
    func duplicatePortIDsAreRejectedAtPersistenceBoundaries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedID = UUID()
        let service = makeService(ports: [
            PortSpec(id: sharedID, port: 3000, isPrimary: true),
            PortSpec(id: sharedID, port: 3001, isPrimary: false),
        ], workingDirectory: directory)
        let invalid = makeProject(name: "Incoming", directory: directory, services: [service])
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [invalid]))
        let store = ProjectStore(directory: directory)
        let existing = makeProject(directory: directory)
        try store.save([existing])
        let original = try Data(contentsOf: store.fileURL)

        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [existing])
        }
        #expect(throws: ValidationFailure.self) { try store.save([existing, invalid]) }
        #expect(try Data(contentsOf: store.fileURL) == original)

        // すでに不正なIDを取り込んだ設定も、編集画面へ渡す前に拒否する。
        try data.write(to: store.fileURL)
        #expect(throws: ProjectStoreError.self) { try store.load() }
    }

    @Test("保存形式を取り込んでもID・起動順・終了順・起動対象・引数を変えない")
    func preservesStoredConfiguration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = [
            makeService(name: "Web", arguments: ["dev", "--label", "two words"], workingDirectory: directory),
            makeService(name: "Worker", ports: [], workingDirectory: directory),
        ]
        let projects = [
            makeProject(
                directory: directory,
                services: services,
                stopOrder: services.map(\.id),
                enabledNow: [services[0].id: false]
            ),
            makeProject(name: "Sample", directory: directory),
        ]
        let data = try JSONEncoder().encode(ProjectsDocument(projects: projects))

        #expect(try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: []) == projects)
        #expect(!FileManager.default.fileExists(atPath: ProjectStore(directory: directory).fileURL.path))
    }

    @Test("空・不正・未対応形式は取り込まない", arguments: [
        "{ not json",
        #"{"projects": []}"#,
        #"{"schemaVersion": 99, "projects": []}"#,
        #"{"schemaVersion": 3, "projects": []}"#,
        #"{"schemaVersion": 3, "projects": [{"name": "Missing fields"}]}"#,
    ])
    func invalidDocumentsFail(json: String) {
        #expect(throws: (any Error).self) {
            try ProjectStore.projectsForImport(Data(json.utf8), path: "input.json", existingProjects: [])
        }
    }

    @Test("登録済みとの名前・ID・サービスIDの重複を拒否する", arguments: ["name", "id", "serviceID"])
    func duplicateExistingConfigurationFails(field: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = makeProject(directory: directory)
        var incoming = makeProject(name: "Incoming", directory: directory)
        switch field {
        case "name": incoming.name = " demo "
        case "id": incoming.id = existing.id
        default:
            incoming.services[0].id = existing.services[0].id
            incoming.workingDirectories[0].serviceIDs = [existing.services[0].id]
        }
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [incoming]))
        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [existing])
        }
    }

    @Test("ファイル内の重複も拒否する")
    func duplicateWithinImportFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = [makeProject(directory: directory), makeProject(directory: directory)]
        let data = try JSONEncoder().encode(ProjectsDocument(projects: projects))
        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [])
        }
    }

    @Test("後半の開発環境に不正なポートがあれば全体を拒否する")
    func invalidLaterProjectFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var invalid = makeProject(name: "Invalid", directory: directory)
        invalid.services[0].ports[0].port = 70_000
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [makeProject(directory: directory), invalid]))
        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [])
        }
    }

    @Test("存在しない作業ディレクトリを取り込まない")
    func missingDirectoryFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeProject(directory: directory.appendingPathComponent("missing"))
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [project]))
        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [])
        }
    }

    @Test("登録済みと同じSupabase project_idを取り込まない")
    func duplicateSupabaseStackFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "shared", in: directory)
        func project(_ name: String) -> ProjectDefinition {
            makeProject(name: name, directory: directory, services: [
                makeService(name: "Supabase", kind: .supabase, executable: "supabase", arguments: ["start"], workingDirectory: directory),
            ])
        }
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [project("Incoming")]))
        #expect(throws: ValidationFailure.self) {
            try ProjectStore.projectsForImport(data, path: "input.json", existingProjects: [project("Existing")])
        }
    }

}
