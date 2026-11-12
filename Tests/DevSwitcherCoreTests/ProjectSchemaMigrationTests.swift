import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("設定スキーマの移行")
struct ProjectSchemaMigrationTests {
    /// schema version 1 の実物と同じ形。v1 には stopOrder / enabledNow / stop が存在しない。
    private func legacyJSON(directory: URL, serviceID: UUID, projectID: UUID) -> String {
        """
        {
          "schemaVersion" : 1,
          "projects" : [
            {
              "id" : "\(projectID.uuidString)",
              "name" : "Bell",
              "color" : "blue",
              "directory" : "\(directory.absoluteString)",
              "services" : [
                {
                  "id" : "\(serviceID.uuidString)",
                  "name" : "Web",
                  "kind" : "web",
                  "enabledByDefault" : true,
                  "failurePolicy" : "block",
                  "ports" : [
                    {
                      "id" : "\(UUID().uuidString)",
                      "port" : 3000,
                      "primary" : true
                    }
                  ],
                  "start" : {
                    "executable" : "/bin/echo",
                    "arguments" : ["hello"],
                    "workingDirectory" : "\(directory.absoluteString)"
                  }
                }
              ]
            }
          ]
        }
        """
    }

    @Test("version 1 を明示的に新形式へ変換して読み込む")
    func migratesVersionOne() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let serviceID = UUID()
        let projectID = UUID()
        try Data(legacyJSON(directory: directory, serviceID: serviceID, projectID: projectID).utf8)
            .write(to: store.fileURL)

        let projects = try store.load()
        let project = try #require(projects.first)

        #expect(project.id == projectID)
        #expect(project.services.map(\.id) == [serviceID])

        // v1 に無かった値は「暗黙の既定」ではなく、v1 の意味を写した明示的な変換結果。
        #expect(project.stopOrder == nil)
        #expect(project.enabledNow.isEmpty)
        #expect(project.services[0].stop == nil)

        // 終了順は起動順の逆、起動対象は enabledByDefault に従う。
        #expect(project.shutdownOrder.map(\.id) == [serviceID])
        #expect(project.isEnabledNow(serviceID))
    }

    @Test("読み込んだ v1 設定は、保存すると現行バージョンで書き出される")
    func savesMigratedProjectsAsCurrentVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacyJSON(directory: directory, serviceID: UUID(), projectID: UUID()).utf8)
            .write(to: store.fileURL)

        try store.save(try store.load())
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"schemaVersion\" : 4"))
    }

    @Test("version 2 を作業パスごとの名前付きディレクトリへ変換する")
    func migratesVersionTwoIntoNamedWorkingDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let webDirectory = directory.appendingPathComponent("web", isDirectory: true)
        let nativeDirectory = directory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)

        let webID = UUID()
        let nativeID = UUID()
        let workerID = UUID()
        let projectID = UUID()
        let store = ProjectStore(directory: directory)
        let json = """
        {
          "schemaVersion" : 2,
          "projects" : [
            {
              "id" : "\(projectID.uuidString)",
              "name" : "Bell",
              "color" : "blue",
              "directory" : "\(directory.absoluteString)",
              "enabledNow" : { "\(nativeID.uuidString)" : false },
              "services" : [
                \(legacyServiceJSON(id: webID, name: "Web", kind: "web", directory: webDirectory)),
                \(legacyServiceJSON(id: nativeID, name: "Native", kind: "expo", directory: nativeDirectory)),
                \(legacyServiceJSON(id: workerID, name: "Worker", kind: "worker", directory: webDirectory))
              ]
            }
          ]
        }
        """
        try Data(json.utf8).write(to: store.fileURL)

        let project = try #require(try store.load().first)
        #expect(project.id == projectID)
        #expect(project.services.map(\.id) == [webID, nativeID, workerID])
        #expect(project.workingDirectories.map(\.name) == ["web", "native"])
        #expect(project.workingDirectories.map(\.directory) == [webDirectory, nativeDirectory])
        #expect(project.workingDirectories[0].serviceIDs == [webID, workerID])
        #expect(project.workingDirectories[1].serviceIDs == [nativeID])
        #expect(project.enabledNow == [nativeID: false])
    }

    private func legacyServiceJSON(
        id: UUID,
        name: String,
        kind: String,
        directory: URL
    ) -> String {
        """
        {
          "id" : "\(id.uuidString)",
          "name" : "\(name)",
          "kind" : "\(kind)",
          "ports" : [],
          "start" : {
            "executable" : "/bin/echo",
            "arguments" : ["hello"],
            "workingDirectory" : "\(directory.absoluteString)"
          },
          "enabledByDefault" : true,
          "failurePolicy" : "block"
        }
        """
    }

    @Test("現行バージョンでは終了順と起動対象を往復できる")
    func roundTripsOrderAndEnabledNow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = makeService(
            name: "Web",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory
        )
        let expo = makeService(
            name: "Expo",
            kind: .expo,
            ports: [PortSpec(port: 8081, isPrimary: true)],
            workingDirectory: directory,
            failurePolicy: .continue
        )
        let project = makeProject(
            directory: directory,
            services: [web, expo],
            stopOrder: [expo.id, web.id],
            enabledNow: [expo.id: false]
        )

        let store = ProjectStore(directory: directory)
        try store.save([project])
        let loaded = try #require(try store.load().first)

        #expect(loaded == project)
        #expect(loaded.stopOrder == [expo.id, web.id])
        #expect(loaded.isEnabledNow(expo.id) == false)
        #expect(loaded.isEnabledNow(web.id))
        #expect(loaded.enabledStartupOrder.map(\.name) == ["Web"])
        #expect(loaded.excludedServices.map(\.name) == ["Expo"])

        let data = try Data(contentsOf: store.fileURL)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try #require(document["projects"] as? [[String: Any]])
        let storedProject = try #require(projects.first)
        #expect(storedProject["directory"] == nil)
        #expect(storedProject["workingDirectories"] != nil)
    }

    @Test("起動対象の指定は人が読める形で保存する")
    func enabledNowIsStoredAsReadableMap() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = makeService(workingDirectory: directory)
        let project = makeProject(
            directory: directory,
            services: [web],
            enabledNow: [web.id: false]
        )
        let store = ProjectStore(directory: directory)
        try store.save([project])

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"\(web.id.uuidString)\" : false"))
    }

    @Test("解釈できない起動対象のキーは既定へ倒さず失敗させる")
    func invalidEnabledNowKeyFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion" : 2,
          "projects" : [
            {
              "id" : "\(UUID().uuidString)",
              "name" : "Bell",
              "color" : "blue",
              "directory" : "\(directory.absoluteString)",
              "enabledNow" : { "not-a-uuid" : false },
              "services" : []
            }
          ]
        }
        """
        try Data(json.utf8).write(to: store.fileURL)

        #expect(throws: ProjectStoreError.self) {
            try store.load()
        }
    }

    @Test("終了順に欠落や未知のサービスがあれば拒否する")
    func rejectsIncompleteStopOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = makeService(name: "Web", ports: [PortSpec(port: 3000, isPrimary: true)], workingDirectory: directory)
        let expo = makeService(
            name: "Expo",
            kind: .expo,
            ports: [PortSpec(port: 8081, isPrimary: true)],
            workingDirectory: directory
        )

        // 1件だけ並べた終了順は、残りを黙って補わずエラーにする。
        let missing = makeProject(
            directory: directory,
            services: [web, expo],
            stopOrder: [web.id]
        )
        #expect(ProjectValidator.validate(missing).contains(.stopOrderMissingService(service: "Expo")))

        let unknownID = UUID()
        let unknown = makeProject(
            directory: directory,
            services: [web, expo],
            stopOrder: [web.id, expo.id, unknownID]
        )
        #expect(ProjectValidator.validate(unknown).contains(.stopOrderUnknownService(id: unknownID)))

        let duplicated = makeProject(
            directory: directory,
            services: [web, expo],
            stopOrder: [web.id, web.id, expo.id]
        )
        #expect(ProjectValidator.validate(duplicated).contains(.stopOrderDuplicate(service: "Web")))
    }

    @Test("存在しないサービスを指す起動対象の指定を拒否する")
    func rejectsUnknownEnabledNowService() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let unknownID = UUID()
        let project = makeProject(directory: directory, enabledNow: [unknownID: true])
        #expect(ProjectValidator.validate(project).contains(.enabledNowUnknownService(id: unknownID)))
    }

    @Test("サービス間でポートが重複していても、起動対象かどうかによらず保存できる")
    func servicesMaySharePorts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = makeService(name: "Web", ports: [PortSpec(port: 3000, isPrimary: true)], workingDirectory: directory)
        let other = makeService(
            name: "Other",
            kind: .other,
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory
        )

        // 両方とも起動対象でも拒否しない。ポートを取れなかった側は起動失敗として扱う。
        let sharing = makeProject(directory: directory, services: [web, other])
        #expect(ProjectValidator.validate(sharing).isEmpty)

        let excluded = makeProject(
            directory: directory,
            services: [web, other],
            enabledNow: [other.id: false]
        )
        #expect(ProjectValidator.validate(excluded).isEmpty)
    }

    @Test("終了コマンドの必須値欠落を拒否する")
    func rejectsInvalidStopCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(
            name: "Worker",
            kind: .worker,
            ports: [PortSpec(label: "API", port: 54_321, isPrimary: true)],
            executable: "/bin/sleep",
            arguments: ["start"],
            workingDirectory: directory,
            stop: CommandSpec(executable: "  ", arguments: [""], workingDirectory: directory)
        )
        let project = makeProject(directory: directory, services: [service])
        let errors = ProjectValidator.validate(project)

        #expect(errors.contains(.stopExecutableEmpty(service: "Worker")))
        #expect(errors.contains(.stopEmptyArgument(service: "Worker", argumentIndex: 0)))
    }
}
