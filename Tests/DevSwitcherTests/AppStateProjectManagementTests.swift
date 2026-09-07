@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 手動のプロジェクト管理（追加・編集・登録解除）を、UI の無効化ではなく
/// `AppState` の API 境界で拒否できているかの検証。
///
/// 登録解除はローカルのリポジトリ・ファイル・ログに一切触らない。
/// 保存に成功してからメモリ上の一覧を変更する。
@Suite("プロジェクトの追加・編集・登録解除")
@MainActor
struct AppStateProjectManagementTests {
    private func makeProject(
        name: String,
        directory: URL,
        serviceNames: [String] = ["Worker"]
    ) -> ProjectDefinition {
        makeWorkerProject(name: name, directory: directory, serviceNames: serviceNames)
    }

    /// プロジェクトディレクトリの中身が消えていないことを確かめるための目印。
    private func makeMarkerFile(in directory: URL) throws -> URL {
        let marker = directory.appendingPathComponent("keep-me.txt", isDirectory: false)
        try Data("dev-switcher".utf8).write(to: marker)
        return marker
    }

    // MARK: - 登録解除

    @Test("登録解除するとファイルからも消え、再読み込みしても復元されない")
    func unregisterRemovesTheProjectFromDisk() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bell = makeProject(name: "Bell", directory: directory)
        let penta = makeProject(name: "Penta", directory: directory)
        let store = ProjectStore(directory: directory)
        try store.save([bell, penta])
        let marker = try makeMarkerFile(in: directory)

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.selection = .project(bell.id)
        state.expandedProjectIDs.insert(bell.id)

        try state.unregisterProject(bell)

        #expect(state.projects.map(\.name) == ["Penta"])
        // 削除対象を指す選択・展開状態を残さない。
        #expect(state.selection == .project(penta.id))
        #expect(!state.expandedProjectIDs.contains(bell.id))
        #expect(state.unregisterPresentation == nil)
        #expect(try store.load().map(\.name) == ["Penta"])

        // ローカルのファイルとディレクトリには触らない。
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))

        // 再読み込みしても復活しない。
        let reopened = makeAppState(directory: directory)
        await reopened.bootstrap()
        #expect(reopened.projects.map(\.name) == ["Penta"])
    }

    @Test("最後の1件を登録解除したら空状態へ遷移する")
    func unregisteringTheLastProjectClearsSelection() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bell = makeProject(name: "Bell", directory: directory)
        try ProjectStore(directory: directory).save([bell])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        #expect(state.selection == .project(bell.id))

        try state.unregisterProject(bell)

        #expect(state.projects.isEmpty)
        #expect(state.selection == nil)
        #expect(state.expandedProjectIDs.isEmpty)
        #expect(try ProjectStore(directory: directory).load().isEmpty)
    }

    @Test("設定を保存できなければ、メモリ上のプロジェクトを削除しない")
    func failedSaveKeepsTheProjectInMemory() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bell = makeProject(name: "Bell", directory: directory)
        let penta = makeProject(name: "Penta", directory: directory)
        let store = ProjectStore(directory: directory)
        try store.save([bell, penta])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.selection = .project(bell.id)

        // 保存だけを決定的に失敗させる。書き込み先をディレクトリに変えると、
        // atomic write の置き換えが「Is a directory」で失敗する。
        // 権限で作ると実行ユーザー（root など）によって結果が変わる。
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try state.unregisterProject(bell) }

        // 一覧・選択状態を登録解除成功として扱わない。
        #expect(state.projects.map(\.name) == ["Bell", "Penta"])
        #expect(state.selection == .project(bell.id))
        #expect(state.project(bell.id) != nil)
    }

    // MARK: - 起動済みプロジェクト

    @Test("起動済みプロジェクトの更新と登録解除を API 境界で拒否し、停止後は実行できる")
    func runningProjectRejectsEditAndUnregister() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        let store = ProjectStore(directory: directory)
        try store.save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        state.loadProjects()
        await state.loadEnvironment()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)
        state.performHandoffAction(.adopt, presentationID: presentation.id)
        await state.waitForPendingOperation()
        #expect(state.phase(of: fixture.project) == .running)

        let originalData = try Data(contentsOf: store.fileURL)
        var renamed = fixture.project
        renamed.name = "Renamed"

        // UI の無効化に依存せず、API 境界で拒否する（DESIGN.md I-1 / I-9）。
        #expect(throws: AppError.self) { try state.updateProject(renamed) }
        #expect(throws: AppError.self) { try state.unregisterProject(fixture.project) }
        #expect(state.canEdit(fixture.project) == false)
        #expect(state.canUnregister(fixture.project) == false)

        // 確認 UI も開かない。理由は黙らせず画面へ出す。
        state.presentUnregisterConfirmation(for: fixture.project)
        #expect(state.unregisterPresentation == nil)
        #expect(state.operationError?.contains("起動済み") == true)
        state.operationError = nil

        #expect(state.projects.map(\.name) == ["Bell"])
        #expect(try Data(contentsOf: store.fileURL) == originalData)

        state.stopProject(fixture.project)
        await state.waitForPendingOperation()
        #expect(state.phase(of: fixture.project) == .stopped)

        // 停止後は同じ操作を実行できる。
        #expect(state.canEdit(fixture.project))
        try state.updateProject(renamed)
        #expect(state.project(fixture.project.id)?.name == "Renamed")

        state.presentUnregisterConfirmation(for: renamed)
        #expect(state.unregisterPresentation?.project.id == renamed.id)

        try state.unregisterProject(renamed)
        #expect(state.projects.isEmpty)
        #expect(try store.load().isEmpty)
    }

    // MARK: - 設定を読み込めない状態

    @Test("設定を読み込めない間は、追加・更新・登録解除を拒否して設定ファイルを変更しない")
    func unreadableStoreRejectsEveryMutation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        // 明示的な変換を持たないスキーマバージョン。古いメモリ内容で上書きしてはいけない。
        let broken = Data(#"{"schemaVersion": 99, "projects": []}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try broken.write(to: store.fileURL)

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        #expect(state.storeError != nil)
        #expect(state.canChangeConfiguration == false)

        let candidate = makeProject(name: "Bell", directory: directory)
        #expect(throws: AppError.self) { try state.addProject(candidate) }
        #expect(throws: AppError.self) { try state.updateProject(candidate) }
        #expect(throws: AppError.self) { try state.unregisterProject(candidate) }

        state.presentProjectForm()
        #expect(state.projectFormPresentation == nil)
        state.presentUnregisterConfirmation(for: candidate)
        #expect(state.unregisterPresentation == nil)

        #expect(state.projects.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == broken)

        // 停止は復旧手段なので、読み込めない間も止めない。
        #expect(state.canStop)
        #expect(state.stopBlockedReason == nil)
        // 起動は拒否する。読めていない一覧を土台に新しいプロセスを起こさない。
        #expect(state.canStart == false)
    }

    @Test("読み込みに成功したあとは、同じ AppState で追加・登録解除できる")
    func recoveredStoreAllowsMutationAgain() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "projects": []}"#.utf8).write(to: store.fileURL)

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        #expect(state.canChangeConfiguration == false)

        // 利用者が原因を解消したことにする。
        try FileManager.default.removeItem(at: store.fileURL)
        await state.retryLoadingProjects()
        #expect(state.storeError == nil)
        #expect(state.canChangeConfiguration)

        let bell = makeProject(name: "Bell", directory: directory)
        try state.addProject(bell)
        #expect(state.projects.map(\.name) == ["Bell"])
        #expect(try store.load().map(\.name) == ["Bell"])

        try state.unregisterProject(bell)
        #expect(state.projects.isEmpty)
        #expect(try store.load().isEmpty)
    }

    // MARK: - 追加と編集

    @Test("編集でサービスを消したら、そのサービスを指す選択状態を残さない")
    func editingAwayAServiceClearsItsSelection() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(name: "Bell", directory: directory, serviceNames: ["Web", "Worker"])
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let removedID = project.services[1].id
        state.selection = .service(projectID: project.id, serviceID: removedID)

        let model = ProjectFormModel(project: project)
        model.removeService(removedID)
        try state.updateProject(try model.build())

        #expect(state.project(project.id)?.services.map(\.name) == ["Web"])
        #expect(state.selection == .project(project.id))
    }

    @Test("複数サービスのプロジェクトを追加し、再読み込みで同じ構成を復元する")
    func addingAMultiServiceProjectRoundTrips() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.services[0].name = "Supabase"
        model.services[0].kind = .supabase
        model.services[0].executable = "/usr/bin/true"
        model.addService()
        model.services[1].name = "Web"
        model.services[1].kind = .web
        model.services[1].executable = "pnpm"
        model.services[1].argumentsText = "dev"
        model.addService()
        model.services[2].name = "Worker"
        model.services[2].kind = .worker
        model.services[2].executable = "/bin/sleep"
        model.services[2].argumentsText = "120"

        let project = try model.build()
        try state.addProject(project)

        #expect(state.projects.map(\.name) == ["Bell"])
        #expect(state.selection == .project(project.id))

        let reopened = makeAppState(directory: directory)
        await reopened.bootstrap()
        let loaded = try #require(reopened.project(project.id))
        #expect(loaded.services.map(\.name) == ["Supabase", "Web", "Worker"])
        #expect(loaded.services.map(\.id) == project.services.map(\.id))
        #expect(loaded == project)
    }
}
