import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DevSwitcherCore
@testable import DevSwitcherApp

@Suite("既存定義からフォームへの追加", .serialized)
@MainActor
struct DefinitionDiscoveryFormTests {
    private func prepare(_ directory: URL) throws -> (ProjectFormModel, DefinitionDiscovery.Result, UUID) {
        try #"{"scripts":{"dev":"node app.js","worker":"node worker.js"}}"#
            .write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "name: shop\nservices: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let model = ProjectFormModel()
        model.name = "Shop"
        model.workingDirectories[0].name = "Web"
        model.workingDirectories[0].directory = directory
        return (model, try DefinitionDiscovery.scan(directory: directory), model.workingDirectories[0].id)
    }

    @Test("選択した候補だけを既定の未入力行に代えて追加し、構造検証を通す")
    func addSelected() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, preview, id) = try prepare(directory)
        try model.addDiscoveredDefinitions(preview, scripts: ["worker"], manager: .pnpm, includeCompose: true, to: id)
        let project = try model.build()
        #expect(project.services.map(\.name) == ["worker"])
        #expect(project.services[0].start.arguments == ["run", "worker"])
        #expect(project.services[0].ports.isEmpty)
        #expect(project.services[0].stop == nil)
        #expect(project.managedStacks.count == 1)
        #expect(project.workingDirectories[0].serviceIDs == project.services.map(\.id))
        #expect(project.workingDirectories[0].stackIDs == project.managedStacks.map(\.id))
        #expect(ProjectValidator.validate(project).isEmpty)
        if case let .dockerCompose(config) = project.managedStacks[0].configuration {
            #expect(config.files == ["compose.yaml"])
            #expect(config.projectName == "shop")
        } else { Issue.record("Compose が別の種類になっています") }
        let store = ProjectStore(directory: directory.appendingPathComponent("settings"))
        try store.save([project])
        #expect(try store.load() == [project])
    }

    @Test("既存の入力・ID・順序・今回の起動対象を保持する")
    func preservesExisting() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (draft, preview, directoryID) = try prepare(directory)
        draft.workingDirectories[0].services[0].name = "Existing"
        draft.workingDirectories[0].services[0].executable = "node"
        draft.workingDirectories[0].services[0].argumentsText = "existing.js"
        let originalServiceID = draft.services[0].id
        var original = try draft.build()
        original.stopOrder = [originalServiceID]
        original.enabledNow = [originalServiceID: false]
        let model = ProjectFormModel(project: original)
        try model.addDiscoveredDefinitions(preview, scripts: ["dev"], manager: .npm, includeCompose: false, to: directoryID)
        let updated = try model.build()
        #expect(updated.id == original.id)
        #expect(updated.services[0] == original.services[0])
        #expect(updated.services.map(\.name) == ["Existing", "dev"])
        #expect(updated.enabledNow == original.enabledNow)
        #expect(updated.stopOrder == updated.services.reversed().map(\.id))
        #expect(updated.services[1].start.executable == "npm")
    }

    @Test("未選択・manager 不明・存在しない候補では入力を変更しない")
    func invalidSelection() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, preview, id) = try prepare(directory)
        let oldIDs = model.services.map(\.id)
        for names: Set<String> in [[], ["dev"], ["absent"]] {
            #expect(throws: DefinitionDiscoveryError.self) {
                try model.addDiscoveredDefinitions(preview, scripts: names, manager: nil, includeCompose: false, to: id)
            }
            #expect(model.services.map(\.id) == oldIDs)
            #expect(model.workingDirectories[0].stacks.isEmpty)
        }
        // Compose だけを選ぶ場合は manager 不明でも取り込める。
        try model.addDiscoveredDefinitions(preview, scripts: [], manager: nil, includeCompose: true, to: id)
        #expect(try model.build().services.isEmpty)
    }

    @Test("内容・lockfile・ディレクトリ変更後は候補の再確認を求める")
    func stalePreview() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, preview, id) = try prepare(directory)
        let oldIDs = model.services.map(\.id)
        try "".write(to: directory.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        #expect(throws: DefinitionDiscoveryError.self) {
            try model.addDiscoveredDefinitions(preview, scripts: ["dev"], manager: .pnpm, includeCompose: false, to: id)
        }
        let fresh = try DefinitionDiscovery.scan(directory: directory)
        model.workingDirectories[0].directory = directory.appendingPathComponent("different")
        #expect(throws: DefinitionDiscoveryError.self) {
            try model.addDiscoveredDefinitions(fresh, scripts: ["dev"], manager: .pnpm, includeCompose: false, to: id)
        }
        #expect(model.services.map(\.id) == oldIDs)
    }

    @Test("重複する名前があると全候補を追加せず、利用者の入力を残す")
    func duplicateIsAtomic() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, preview, id) = try prepare(directory)
        model.workingDirectories[0].services[0].name = "DEV"
        let oldIDs = model.services.map(\.id)
        #expect(throws: DefinitionDiscoveryError.self) {
            try model.addDiscoveredDefinitions(preview, scripts: ["dev", "worker"], manager: .bun, includeCompose: true, to: id)
        }
        #expect(model.services.map(\.id) == oldIDs)
        #expect(model.services[0].name == "DEV")
        #expect(model.workingDirectories[0].stacks.isEmpty)
    }

    @Test("入力を変更した空欄のプロセスは自動削除しない")
    func preservesPartialDraft() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, preview, id) = try prepare(directory)
        model.workingDirectories[0].services[0].argumentsText = "--pending"
        let oldID = model.services[0].id
        try model.addDiscoveredDefinitions(preview, scripts: ["dev"], manager: .yarn, includeCompose: false, to: id)
        #expect(model.services[0].id == oldID)
        #expect(model.services[0].argumentsText == "--pending")
        #expect(model.services.count == 2)
    }

    @Test("候補数に応じた高さで、少数・多数・長文・空・エラーを描画する")
    func renderCandidates() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _, directoryID) = try prepare(directory)
        try "".write(to: directory.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        let preview = try DefinitionDiscovery.scan(directory: directory)
        let short = try await render(preview, file: "dev-switcher-definition-discovery")
        #expect(short.height < 320)
        _ = try await render(preview, file: "dev-switcher-definition-discovery-dark", scheme: .dark)

        let scripts = ["scripts": ["dev": "node app.js --description '" + String(repeating: "長いコマンドの表示確認 ", count: 12) + "'",
                                   "worker": "node worker.js"]]
        try JSONEncoder().encode(scripts).write(to: directory.appendingPathComponent("package.json"))
        try "".write(to: directory.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        let long = try await render(DefinitionDiscovery.scan(directory: directory), file: "dev-switcher-definition-discovery-long")
        #expect(long.height > short.height)

        let manyScripts = ["scripts": Dictionary(uniqueKeysWithValues: (1...12).map { ("worker-\($0)", "node worker-\($0).js") })]
        try JSONEncoder().encode(manyScripts).write(to: directory.appendingPathComponent("package.json"))
        let many = try await render(DefinitionDiscovery.scan(directory: directory), file: "dev-switcher-definition-discovery-many")
        #expect(many.height > long.height)

        try "{".write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        _ = try await render(DefinitionDiscovery.scan(directory: directory), file: "dev-switcher-definition-discovery-error")
        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        _ = try await render(DefinitionDiscovery.scan(directory: empty), file: "dev-switcher-definition-discovery-empty")

        // 実際の編集シートの幅でも、見出しと入力行のまとまりを確認する。
        try #"{"scripts":{"dev":"node app.js","worker":"node worker.js"}}"#
            .write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let restored = try DefinitionDiscovery.scan(directory: directory)
        try model.addDiscoveredDefinitions(restored, scripts: ["dev"], manager: .pnpm, includeCompose: true, to: directoryID)
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, stackDrivers: [:])
        let state = AppState(registry: registry, store: ProjectStore(directory: directory), hintStore: RuntimeHintStore(directory: directory))
        _ = try await capture(ProjectFormView(project: model.build()).environment(state)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light),
            file: "dev-switcher-definition-editor")
    }

    private func render(_ preview: DefinitionDiscovery.Result, file: String, scheme: ColorScheme = .light) async throws -> NSSize {
        let view = DefinitionDiscoveryView(directory: preview.directory, preview: preview) { _, _, _, _ in }
            .frame(width: Metrics.editorSheetWidth - Spacing.l * 2 - Spacing.m * 2)
            .padding(Spacing.l)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        return try await capture(view, file: file)
    }

    private func capture<V: View>(_ view: V, file: String) async throws -> NSSize {
        let controller = NSHostingController(rootView: view)
        let size = controller.view.fittingSize
        #expect(size.width > 0 && size.height > 0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/private/tmp/\(file).png"))
        return size
    }
}
