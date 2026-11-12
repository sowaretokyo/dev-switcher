import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DevSwitcherCore
@testable import DevSwitcherApp

@Suite("日本語・英語の表示")
struct LocalizationTests {
    @Test("Mac の優先言語順・地域差・未対応言語を扱う")
    func languagePreferences() {
        #expect(AppLocalization.Language.preferred(["ja-JP", "en-US"]) == .japanese)
        #expect(AppLocalization.Language.preferred(["en-GB", "ja"]) == .english)
        #expect(AppLocalization.Language.preferred(["fr-FR", "ja-JP"]) == .japanese)
        #expect(AppLocalization.Language.preferred(["de-DE"]) == .english)
        #expect(AppLocalization.Language.preferred([]) == .english)
    }

    @Test("停止済みと停止処理中を英語でも区別する")
    func stoppingProgress() throws {
        let english = try AppLocalization(language: .english)
        L10n.$override.withValue(english) {
            #expect(ServicePhase.stopped.label == "Stopped")
            #expect(AppState.InlineOperation.Kind.stopping.label == "Stopping")
            let operation = AppState.ServiceOperation(projectID: UUID(), serviceID: UUID(), kind: .restarting,
                state: .stopping(service: "Worker", index: 1, total: 1))
            #expect(operation.label == "Stopping")
        }
    }

    @Test("停止時の翻訳を繰り返しても再帰しない", arguments: AppLocalization.Language.allCases)
    func repeatedStopMessages(language: AppLocalization.Language) throws {
        let localization = try AppLocalization(language: language)
        let identity = try ManagedStackIdentity(type: .supabase, value: "demo")
        L10n.$override.withValue(localization) {
            for _ in 0..<1_000 {
                #expect(!L10n.text("停止").isEmpty)
                let failure = ManagedStackOperationError.commandFailed(
                    action: L10n.text("停止"),
                    identity: identity,
                    status: .exited(code: 1),
                    output: ""
                )
                #expect(!failure.description.isEmpty)
            }
        }
    }

    @Test("日英で引数を並べ替え、利用者名を翻訳・再置換しない")
    func interpolationPreservesUserData() throws {
        let name = "起動 {0} 100% 🐈"
        let port = "not-a-number"
        let english = try AppLocalization(language: .english)
        let japanese = try AppLocalization(language: .japanese)
        let message: LocalizedMessage = "プロセス「\(name)」のポート「\(port)」は数値として解釈できません。"
        #expect(english.render(message) == "Port “not-a-number” for process “起動 {0} 100% 🐈” is not a number.")
        #expect(japanese.render(message) == "プロセス「起動 {0} 100% 🐈」のポート「not-a-number」は数値として解釈できません。")
    }

    @Test("全翻訳のキーと引数が揃い、日本語原文を保持する")
    func completeCatalog() throws {
        let bundle = try AppResources.bundle()
        let root = try #require(bundle.resourceURL)
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let ja = try table("ja"), en = try table("en")
        #expect(Set(ja.keys) == Set(en.keys))
        let english = try AppLocalization(language: .english)
        let japanese = try AppLocalization(language: .japanese)
        let regex = try NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        for (key, original) in ja {
            #expect(original == key)
            let matches = regex.matches(in: key, range: NSRange(key.startIndex..., in: key))
            let indices = matches.map { Int((key as NSString).substring(with: $0.range(at: 1)))! }
            let arguments = (0..<(indices.max().map { $0 + 1 } ?? 0)).map { "ARG_\($0)_%_{literal}" }
            let message = LocalizedMessage(key: key, arguments: arguments)
            #expect(!english.render(message).isEmpty)
            #expect(!japanese.render(message).isEmpty)
            for argument in arguments { #expect(english.render(message).contains(argument)) }
        }
    }

    @Test("状態と入れ子のエラーを選択言語で表示し、ログ本文は維持する")
    func nestedErrors() throws {
        let english = try AppLocalization(language: .english)
        let originalLog = "ユーザーのログ: pnpm dev --port 3000"
        L10n.$override.withValue(english) {
            #expect(ServicePhase.healthy.label == "Started")
            #expect(ServicePhase.stopping.label == "Stopping")
            #expect(ProjectPhase.degraded(stoppedServices: ["Web"]).label == "Partially stopped")
            let inner = ValidationError.executableEmpty(service: "日本語Web")
            let outer = RuntimeError.managedCommandInvalid(service: "日本語Web", reason: inner.description + "\n" + originalLog)
            #expect(outer.description.contains("has no executable"))
            #expect(outer.description.contains("Cannot construct the managed command"))
            #expect(outer.description.contains("日本語Web"))
            #expect(outer.description.contains(originalLog))
            let handoff = RuntimeError.invalidHandoff(service: "日本語Web", reason: originalLog)
            #expect(handoff.description == "Could not revalidate the adoption candidate for service “日本語Web” immediately before registration. Adoption was cancelled to avoid managing a different process.\n" + originalLog)
            let identity = HandoffRejection.anchorMismatch(expected: .init(pid: 42, startAbstime: 100), actual: 200)
            #expect(identity.description == "Process identity mismatch (recorded PID 42, start abstime: 100 / observed: 200). The PID may have been reused.")
        }
        #expect(ServicePhase.healthy.label == "起動済み", "テストの言語指定を他の処理へ漏らさない")
    }

    @Test("日英のガイドが同じ v4 サンプルを生成し、設定データに翻訳が混ざらない")
    @MainActor
    func guidesAndSettings() throws {
        let ja = try ProjectImportModel.creationGuide(language: .japanese)
        let en = try ProjectImportModel.creationGuide(language: .english)
        #expect(ja.hasPrefix("# Dev Switcherの取り込み用JSON"))
        #expect(en.hasPrefix("# Create Dev Switcher import JSON"))
        #expect(en.contains("## Example\n"))
        #expect(!en.contains("## サンプル"))
        func sample(_ guide: String) throws -> String {
            let section = try #require(guide.components(separatedBy: "```json\n").last)
            return try #require(section.components(separatedBy: "\n```").first)
        }
        #expect(try sample(ja) == sample(en))
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = try sample(en).replacingOccurrences(of: "file:///ABSOLUTE/PATH/TO/web/", with: directory.absoluteString)
        let projects = try ProjectStore.projectsForImport(Data(json.utf8), path: "example", existingProjects: [])
        let document = ProjectsDocument(projects: projects)
        let original = try document.jsonData()
        let english = try AppLocalization(language: .english)
        let translated = try L10n.$override.withValue(english) { try document.jsonData() }
        #expect(original == translated)
    }

    @Test("移動したアプリの同梱翻訳を使い、欠落した英語を日本語で補わない")
    func relocatedResources() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appendingPathComponent("DevSwitcher.app")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "localization.tests.\(UUID())", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let copy = resourcesURL.appendingPathComponent("\(AppResources.bundleName).bundle")
        try FileManager.default.copyItem(at: AppResources.bundle().bundleURL, to: copy)
        let app = try #require(Bundle(url: appURL))
        let bundle = try AppResources.bundle(for: app)
        #expect(try AppLocalization(language: .english, resources: bundle).render("起動") == "Start")
        #expect(try AppLocalization(language: .japanese, resources: bundle).render("起動") == "起動")
        let root = try #require(bundle.resourceURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("en.lproj/Localizable.strings"))
        #expect(throws: (any Error).self) { try AppLocalization(language: .english, resources: bundle) }
    }
}

@Suite("日英の最小ウィンドウ描画", .serialized)
@MainActor
struct LocalizationLayoutTests {
    @Test("英語の説明が長くても詳細が最小ウィンドウ内に収まる", arguments: AppLocalization.Language.allCases)
    func detailLayout(language: AppLocalization.Language) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeWorkerProject(name: "Bilingual workspace", directory: directory)
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        state.selection = .service(projectID: project.id, serviceID: project.services[0].id)
        let localization = try AppLocalization(language: language)
        try await L10n.$override.withValue(localization) {
            let controller = NSHostingController(rootView: RootView().environment(state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.windowMinWidth, height: Metrics.windowMinHeight),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.fittingSize.height <= Metrics.windowMinHeight)
        }
    }

    @Test("日英の編集フォームと操作確認を描画する", arguments: AppLocalization.Language.allCases)
    func editorAndConfirmation(language: AppLocalization.Language) throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "services: {}".write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let stack = ManagedStackDefinition(id: UUID(), name: "DB and Worker", configuration: .dockerCompose(.init(projectName: "shop", files: ["compose.yaml"], profiles: ["dev"], upArguments: ["--wait"])), ports: [], enabledByDefault: true, failurePolicy: .block)
        let project = ProjectDefinition(name: "Shop", color: .green, workingDirectories: [.init(name: "Backend", directory: directory, serviceIDs: [], stackIDs: [stack.id])], services: [], managedStacks: [stack])
        let state = makeAppState(directory: directory)
        let localization = try AppLocalization(language: language)
        try L10n.$override.withValue(localization) {
            let editor = ProjectFormView(project: project).environment(state)
            let editorSize = NSHostingController(rootView: editor).view.fittingSize
            #expect(editorSize.width == Metrics.editorSheetWidth)
            #expect(editorSize.height == Metrics.editorSheetHeight)
            let resolved = try ResolvedManagedStack(environmentID: project.id, definition: stack, workingDirectory: directory)
            let plan = ManagedStackConfirmationPlan(environmentName: project.name,
                entries: [.init(stackID: stack.id, identity: resolved.identity, state: .degraded, action: .restart, registration: .init(environmentName: project.name, stackName: stack.name, directory: directory))],
                snapshot: ManagedStackSnapshot(type: .dockerCompose, observations: [.init(identity: resolved.identity, state: .degraded)]), fingerprints: [stack.id: resolved.fingerprint])
            let presentation = AppState.ManagedStackConfirmationPresentation(projectID: project.id, plan: plan)
            let confirmation = ManagedStackConfirmationSheet(presentation: presentation).environment(state)
            let confirmationSize = NSHostingController(rootView: confirmation).view.fittingSize
            #expect(confirmationSize.width == Metrics.sheetWidth)
            #expect(confirmationSize.height > 0 && confirmationSize.height < Metrics.editorSheetHeight)
        }
    }

}
