import Foundation
import Testing
@testable import DevSwitcherCore
@testable import DevSwitcherApp

@Suite("開発環境の一括取り込み")
@MainActor
struct AppStateProjectImportTests {
    @Test("取り込んだ複数行や空白付きの引数は、名前だけの編集と再保存で変わらない", arguments: [
        ["-c", "printf first\nprintf second"],
        ["-c", "\n  printf first\r\n\r\n  printf second\n"],
        ["--label", "  two words\t", "literal\\n"],
    ])
    func importedArgumentsSurviveRenameAndReload(arguments: [String]) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        var incoming = makeWorkerProject(name: "Incoming", directory: directory)
        incoming.services[0].start = CommandSpec(
            executable: "/bin/sh",
            arguments: arguments,
            workingDirectory: directory
        )
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [incoming]))
        let preview = try state.previewProjectImport(data, path: "input.json")
        try state.importProjects(preview)

        let model = ProjectFormModel(project: try #require(state.project(incoming.id)))
        model.name = "Renamed"
        try state.updateProject(model.build())

        var expected = incoming
        expected.name = "Renamed"
        #expect(state.projects == [expected])
        #expect(try ProjectStore(directory: directory).load() == [expected])
    }

    @Test("確認時は変更せず、一括追加後もコマンドを実行しない")
    func previewAndImportDoNotRunCommands() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = makeWorkerProject(name: "Existing", directory: directory)
        let marker = directory.appendingPathComponent("must-not-run")
        var first = makeWorkerProject(name: "First", directory: directory)
        first.services[0].start = CommandSpec(executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: directory)
        let incoming = [first, makeWorkerProject(name: "Second", directory: directory)]
        let store = ProjectStore(directory: directory)
        try store.save([existing])
        let original = try Data(contentsOf: store.fileURL)
        let state = makeAppState(directory: directory)
        await state.bootstrap()

        let data = try JSONEncoder().encode(ProjectsDocument(projects: incoming))
        state.presentProjectImport()
        let preview = try state.previewProjectImport(data, path: "input.json")
        #expect(state.isProjectImportPresented)
        #expect(state.projects == [existing])
        #expect(try Data(contentsOf: store.fileURL) == original)

        try state.importProjects(preview)
        #expect(state.projects == [existing] + incoming)
        #expect(try store.load() == [existing] + incoming)
        #expect(state.selection == .project(first.id))
        #expect(!state.isProjectImportPresented)
        #expect(state.activeProject == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("後半が不正でも先頭だけを登録しない")
    func invalidBatchDoesNotPartiallySave() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = makeWorkerProject(name: "Existing", directory: directory)
        let store = ProjectStore(directory: directory)
        try store.save([existing])
        let original = try Data(contentsOf: store.fileURL)
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let first = makeWorkerProject(name: "First", directory: directory)
        let invalid = makeWorkerProject(name: "", directory: directory)

        #expect(throws: ValidationFailure.self) { try state.importProjects([first, invalid]) }
        #expect(state.projects == [existing])
        #expect(state.selection == .project(existing.id))
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test("確認後に同じ設定が追加されたら再検証で拒否する")
    func revalidatesDuplicatesAtSave() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let incoming = makeWorkerProject(name: "Incoming", directory: directory)
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [incoming]))
        let preview = try state.previewProjectImport(data, path: "input.json")
        try state.addProject(incoming)

        #expect(throws: ValidationFailure.self) { try state.importProjects(preview) }
        #expect(state.projects == [incoming])
        #expect(try ProjectStore(directory: directory).load() == [incoming])
    }

    @Test("確認後に作業ディレクトリが無くなったら保存しない")
    func revalidatesDirectoryAtSave() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let incoming = makeWorkerProject(name: "Incoming", directory: workingDirectory)
        let data = try JSONEncoder().encode(ProjectsDocument(projects: [incoming]))
        let preview = try state.previewProjectImport(data, path: "input.json")
        try FileManager.default.removeItem(at: workingDirectory)

        #expect(throws: ValidationFailure.self) { try state.importProjects(preview) }
        #expect(state.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ProjectStore(directory: directory).fileURL.path))
    }

    @Test("保存失敗時は一覧と確認画面を維持する")
    func failedSaveKeepsMemoryAndPresentation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory)
        let existing = makeWorkerProject(name: "Existing", directory: directory)
        try store.save([existing])
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.presentProjectImport()
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        #expect(throws: ProjectStoreError.self) {
            try state.importProjects([makeWorkerProject(name: "Incoming", directory: directory)])
        }
        #expect(state.projects == [existing])
        #expect(state.selection == .project(existing.id))
        #expect(state.isProjectImportPresented)
    }

    @Test("既存設定が未読または読込失敗なら取り込みの全入口を拒否する")
    func unreadableStoreBlocksImport() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = makeAppState(directory: directory)
        let incoming = [makeWorkerProject(name: "Incoming", directory: directory)]
        let data = try JSONEncoder().encode(ProjectsDocument(projects: incoming))
        func assertBlocked() {
            state.presentProjectImport()
            #expect(!state.isProjectImportPresented)
            #expect(state.operationError != nil)
            #expect(throws: AppError.self) { try state.previewProjectImport(data, path: "input.json") }
            #expect(throws: AppError.self) { try state.importProjects(incoming) }
        }
        assertBlocked()
        let store = ProjectStore(directory: directory)
        let broken = Data("{ broken".utf8)
        try broken.write(to: store.fileURL)
        await state.bootstrap()
        assertBlocked()
        #expect(try Data(contentsOf: store.fileURL) == broken)
    }
}
