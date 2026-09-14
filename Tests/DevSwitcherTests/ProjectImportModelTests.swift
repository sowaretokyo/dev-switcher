import Foundation
import Testing
@testable import DevSwitcherCore
@testable import DevSwitcherApp

@Suite("JSON取り込みの確認画面")
@MainActor
struct ProjectImportModelTests {
    @Test("コピー用ガイドのサンプルを取り込み、確認内容と同じJSONを保存できる")
    func guideExampleCanBePreviewedAndSaved() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let guide = try ProjectImportModel.creationGuide()
        #expect(guide.contains("serviceIDs"))
        let sections = guide.components(separatedBy: "```json\n")
        try #require(sections.count == 2)
        let example = try #require(sections[1].components(separatedBy: "\n```").first)
        let json = example.replacingOccurrences(
            of: "file:///ABSOLUTE/PATH/TO/web/",
            with: directory.absoluteString
        )
        let input = directory.appendingPathComponent("input.json")
        try Data(json.utf8).write(to: input)

        let model = ProjectImportModel()
        model.read(.success(input), validate: validate)
        let preview = try #require(model.preview)
        #expect(model.errorMessage == nil)
        #expect(model.fileName == "input.json")
        #expect(model.projectCount == 1)
        #expect(preview.projects[0].services.map(\.name) == ["Web", "Worker"])
        #expect(preview.projects[0].services[1].ports.isEmpty)

        let store = ProjectStore(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.save(preview.projects)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == preview.json)
        #expect(try store.load() == preview.projects)
    }

    enum Failure: CaseIterable {
        case selection
        case missingFile
        case malformedJSON
        case invalidConfiguration
        case operationBlocked
    }

    @Test("別ファイルの読み込みが失敗したら以前の確認内容を破棄し、再読込で復旧できる", arguments: Failure.allCases)
    func failedReadClearsPreviousPreview(failure: Failure) throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeWorkerProject(name: "Incoming", directory: directory)
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [project]))
        let input = directory.appendingPathComponent("input.json")
        try data.write(to: input)
        let model = ProjectImportModel()
        model.read(.success(input), validate: validate)
        #expect(model.preview?.projects == [project])

        switch failure {
        case .selection:
            model.read(.failure(CocoaError(.fileReadNoPermission)), validate: validate)
        case .missingFile:
            model.read(.success(directory.appendingPathComponent("missing.json")), validate: validate)
        case .malformedJSON:
            try Data("{ broken".utf8).write(to: input)
            model.read(.success(input), validate: validate)
        case .invalidConfiguration:
            model.read(.success(input)) { data, path in
                try ProjectStore.projectsForImport(data, path: path, existingProjects: [project])
            }
        case .operationBlocked:
            model.read(.success(input)) { _, _ in
                throw AppError.busy("起動処理を実行中です。")
            }
        }

        #expect(model.preview == nil)
        #expect(model.projectCount == 0)
        #expect(model.errorMessage?.contains("取り込めません") == true)

        try data.write(to: input)
        model.read(.success(input), validate: validate)
        #expect(model.preview?.projects == [project])
        #expect(model.projectCount == 1)
        #expect(model.errorMessage == nil)
    }

    private func validate(_ data: Data, path: String) throws -> [ProjectDefinition] {
        try ProjectStore.projectsForImport(data, path: path, existingProjects: [])
    }
}
