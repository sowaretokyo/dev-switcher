import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DevSwitcherCore
@testable import DevSwitcherApp

@Suite("Compose の編集と確認表示", .serialized)
@MainActor
struct ComposeEditorTests {
    private func project(_ directory: URL) throws -> ProjectDefinition {
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let stack = ManagedStackDefinition(id: UUID(), name: "DB と Worker", configuration: .dockerCompose(.init(projectName: "shop", files: ["compose.yaml"], profiles: ["dev"], upArguments: ["--wait", "--pull", "never"])), ports: [PortSpec(label: "DB", port: 5432, isPrimary: true)], enabledByDefault: true, failurePolicy: .block)
        return ProjectDefinition(name: "Shop", color: .green, workingDirectories: [.init(name: "Backend", directory: directory, serviceIDs: [], stackIDs: [stack.id])], services: [DevSwitcherCore.ServiceDefinition](), managedStacks: [stack], enabledNow: [stack.id: false])
    }
    @Test("Compose の全設定・ID・起動対象を編集の往復で保持する")
    func roundTrip() throws {
        let directory = try makeTemporaryTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try project(directory)
        let model = ProjectFormModel(project: original)
        #expect(model.services.isEmpty)
        let draft = try #require(model.workingDirectories.first?.stacks.first)
        #expect(draft.type == .dockerCompose)
        #expect(draft.profilesJSON == "[\"dev\"]")
        #expect(try model.build() == original)
        model.workingDirectories[0].stacks[0].projectName = "shop-edited"
        let rebuilt = try model.build()
        #expect(rebuilt.managedStacks[0].id == original.managedStacks[0].id)
        #expect(rebuilt.enabledNow == original.enabledNow)
        if case let .dockerCompose(config) = rebuilt.managedStacks[0].configuration { #expect(config.projectName == "shop-edited") }
        else { Issue.record("Compose が別の種類に変わりました") }
    }
    @Test("Compose の編集・引き継ぎ・復旧・起動失敗の画面を描画できる")
    func renderViews() async throws {
        let directory = try makeTemporaryTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = try project(directory)
        let registry = RuntimeRegistry(logDirectory: directory, environmentLoader: { fixedShellEnvironment }, stackDrivers: [:])
        let state = AppState(registry: registry, store: ProjectStore(directory: directory), hintStore: RuntimeHintStore(directory: directory))
        let output = directory.appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await render(ProjectFormView(project: value).environment(state), size: NSSize(width: Metrics.editorSheetWidth, height: Metrics.editorSheetHeight), to: output.appendingPathComponent("editor.png"))
        let unit = try #require(value.launchUnits.first)
        #expect(ManagedStackTypePresentation.detailRows(for: unit).count == 5)
        let resolved = try ResolvedManagedStack(environmentID: value.id, definition: value.managedStacks[0], workingDirectory: directory)
        for (action, observed) in [(ManagedStackConfirmationTarget.Action.adopt, ManagedStackState.running), (.restart, .degraded)] {
            let plan = ManagedStackConfirmationPlan(environmentName: value.name,
                entries: [.init(stackID: resolved.stackID, identity: resolved.identity, state: observed, action: action, registration: .init(environmentName: value.name, stackName: resolved.stackName, directory: directory))],
                snapshot: ManagedStackSnapshot(type: .dockerCompose, observations: [.init(identity: resolved.identity, state: observed)]), fingerprints: [resolved.stackID: resolved.fingerprint])
            let presentation = AppState.ManagedStackConfirmationPresentation(projectID: value.id, plan: plan)
            #expect(presentation.title.contains("Docker Compose"))
            #expect(ConfirmationSheetContent(plan: plan).notes.contains { $0.contains("全 profile") })
            let controller = NSHostingController(rootView: ManagedStackConfirmationSheet(presentation: presentation).environment(state))
            let size = controller.view.fittingSize
            #expect(size.width > 0 && size.height > 0)
            try await render(ManagedStackConfirmationSheet(presentation: presentation).environment(state), size: size, to: output.appendingPathComponent(action == .adopt ? "adopt.png" : "restart.png"))
        }
        let fact = ProjectFact(projectID: value.id, projectName: value.name, phase: .failed(reason: "起動失敗"), services: [.init(serviceID: unit.id, name: unit.name, phase: .failed(reason: "Docker unavailable"), observedPorts: .unavailable)])
        let failure = SwitchFailure(reason: .startFailed(service: unit.name, reason: "Docker unavailable"), facts: CurrentStateFacts(source: nil, target: fact))
        let presentation = AppState.FailurePresentation(failure: failure, logTarget: .service(projectID: value.id, serviceID: unit.id))
        let view = SwitchFailureSheet(presentation: presentation).environment(state)
        let controller = NSHostingController(rootView: view)
        try await render(view, size: controller.view.fittingSize, to: output.appendingPathComponent("failure.png"))
    }
    private func render<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let controller = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.fittingSize.height <= size.height + 1)
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
