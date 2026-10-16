import AppKit
@testable import DevSwitcherApp
@testable import DevSwitcherCore
import SwiftUI
import Testing

@Suite("再起動時の警告と画面サイズ", .serialized)
@MainActor
struct RootViewLayoutTests {
    @Test("警告の件数・長さによらず一覧と詳細がウィンドウ内に収まる",
          arguments: [0, 1, 30], [false, true])
    func startupErrorsFitWindow(messageLines: Int, selectsService: Bool) async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "layout-test", in: directory)
        let service = makeAppStateSupabaseService(workingDirectory: directory)
        let project = ProjectDefinition(
            name: "Bell", color: .blue, directory: directory, services: [service]
        )
        try ProjectStore(directory: directory).save([project])
        let stackID = try #require(SupabaseProjectID(rawValue: "layout-test"))
        let hint = try #require(ManagedRuntimeHint(
            projectID: project.id, service: service,
            supabaseProjectID: stackID, relationship: .launched
        ))
        try RuntimeHintStore(directory: directory).save([], legacy: [], managed: [hint])
        let world = FakeSupabaseWorld()
        if messageLines > 0 {
            let message = Array(
                repeating: "Cannot connect to the Docker daemon. Is the docker daemon running?",
                count: messageLines
            ).joined(separator: "\n")
            await world.failInventory(message)
        }
        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        state.selection = selectsService
            ? .service(projectID: project.id, serviceID: service.id)
            : .project(project.id)

        let controller = NSHostingController(rootView: RootView().environment(state))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: Metrics.windowMinWidth, height: Metrics.windowMinHeight
            ),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        // NavigationSplitView内部のAppKit制約が反映されるまで待つ。
        // 装着前のsizeThatFitsは460を返しても、装着後の高さが膨らむことがある。
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.fittingSize.height <= Metrics.windowMinHeight)
        let split = try #require(splitView(in: controller.view))
        let bounds = split.convert(split.bounds, to: controller.view)
        #expect(bounds.minY >= 0)
        #expect(bounds.maxY <= controller.view.bounds.height)
        if messageLines == 30 {
            let bannerScroll = try #require(scrollViews(in: split).first {
                $0.documentView != nil && !($0.documentView is NSTableView)
            })
            let document = try #require(bannerScroll.documentView)
            #expect(bannerScroll.bounds.height <= Metrics.bannerAreaMaxHeight)
            #expect(document.bounds.height > bannerScroll.contentView.bounds.height,
                    "長い警告は切り捨てず、スクロールして全文を読める")
        }
        if messageLines == 0, !selectsService {
            let detailScroll = try #require(scrollViews(in: split).first {
                $0.documentView != nil && !($0.documentView is NSTableView)
            })
            let detailBounds = detailScroll.convert(detailScroll.bounds, to: controller.view)
            #expect(detailBounds.minY == 0, "警告がないときは上部に空欄を残さない")
        }
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}
