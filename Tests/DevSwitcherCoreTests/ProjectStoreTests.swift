import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("設定の保存と読み込み")
struct ProjectStoreTests {
    @Test("保存した内容をそのまま読み戻せる")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            ports: [
                PortSpec(label: "API", port: 54_321, isPrimary: true, openURL: "http://localhost:54321"),
                PortSpec(label: "DB", port: 54_322, isPrimary: false),
            ],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])

        try store.save([project])
        let loaded = try store.load()

        #expect(loaded == [project])
    }

    @Test("ファイルがなければ空の一覧を返す")
    func missingFileIsEmpty() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        #expect(try store.load().isEmpty)
    }

    @Test("保存ファイルに稼働状態を含めない")
    func savedFileContainsNoRuntimeState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try store.save([makeProject(directory: directory)])

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"schemaVersion\" : \(ProjectsDocument.currentSchemaVersion)"))
        for forbidden in ["\"pid\"", "\"processGroupID\"", "\"observedPorts\"", "\"phase\"", "\"running\"", "\"startedAt\""] {
            #expect(!json.contains(forbidden), "保存ファイルに稼働状態 \(forbidden) が含まれている")
        }
    }

    @Test("壊れた JSON は読み込みで失敗させる")
    func brokenJSONFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }

    @Test("未対応のスキーマバージョンを読み込まない")
    func futureSchemaVersionFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "projects": []}"#.utf8).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }

    @Test("必須値が欠けた保存済み設定を受け付けない")
    func invalidStoredProjectFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 代表ポートが無い状態のファイルを直接書き込む。
        let json = """
        {
          "projects" : [
            {
              "color" : "blue",
              "directory" : "file://\(directory.path)",
              "id" : "\(UUID().uuidString)",
              "name" : "Bell",
              "services" : [
                {
                  "enabledByDefault" : true,
                  "failurePolicy" : "block",
                  "id" : "\(UUID().uuidString)",
                  "kind" : "web",
                  "name" : "Web",
                  "ports" : [
                    { "id" : "\(UUID().uuidString)", "port" : 3000, "primary" : false }
                  ],
                  "start" : {
                    "arguments" : [ "hello" ],
                    "executable" : "/bin/echo",
                    "workingDirectory" : "file://\(directory.path)"
                  }
                }
              ]
            }
          ],
          "schemaVersion" : 1
        }
        """
        try Data(json.utf8).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }

    @Test("ID が重複したプロジェクトを保存しない")
    func duplicateProjectIDIsNotSaved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        let sharedID = UUID()
        let first = ProjectDefinition(
            id: sharedID,
            name: "Bell",
            color: .blue,
            directory: directory,
            services: [makeService(workingDirectory: directory)]
        )
        let second = ProjectDefinition(
            id: sharedID,
            name: "Penta",
            color: .green,
            directory: directory,
            services: [makeService(workingDirectory: directory)]
        )

        #expect(throws: ValidationFailure.self) {
            try store.save([first, second])
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("ID が重複した保存済み設定を読み込まない")
    func duplicateProjectIDIsNotLoaded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sharedID = UUID().uuidString
        func projectJSON(name: String) -> String {
            """
            {
              "color" : "blue",
              "directory" : "file://\(directory.path)",
              "id" : "\(sharedID)",
              "name" : "\(name)",
              "services" : [
                {
                  "enabledByDefault" : true,
                  "failurePolicy" : "block",
                  "id" : "\(UUID().uuidString)",
                  "kind" : "web",
                  "name" : "Web",
                  "ports" : [],
                  "start" : {
                    "arguments" : [ "hello" ],
                    "executable" : "/bin/echo",
                    "workingDirectory" : "file://\(directory.path)"
                  }
                }
              ]
            }
            """
        }
        let json = """
        { "projects" : [ \(projectJSON(name: "Bell")), \(projectJSON(name: "Penta")) ], "schemaVersion" : 1 }
        """
        try Data(json.utf8).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }

    @Test("不正な設定は保存前に失敗させる")
    func invalidProjectIsNotSaved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        let project = makeProject(name: "", directory: directory)

        #expect(throws: ValidationFailure.self) {
            try store.save([project])
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("保存済みの別プロジェクト間でサービスIDが重複していれば読み込まない")
    func duplicateServiceIDAcrossStoredProjectsFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let serviceID = UUID()
        func service(named name: String) -> ServiceDefinition {
            ServiceDefinition(
                id: serviceID,
                name: name,
                kind: .worker,
                ports: [],
                start: CommandSpec(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    workingDirectory: directory
                ),
                enabledByDefault: true,
                failurePolicy: .block
            )
        }
        let projects = [
            makeProject(name: "First", directory: directory, services: [service(named: "A")]),
            makeProject(name: "Second", directory: directory, services: [service(named: "B")]),
        ]
        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectsDocument(projects: projects)).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }
}
