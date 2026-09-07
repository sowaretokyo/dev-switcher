import AppKit
import SwiftUI

/// アプリ本体。起動は `DevSwitcherMain` の `main.swift` から行う。
/// `@main` をここへ付けると実行可能ターゲットになり、テストから import できなくなる。
public struct DevSwitcherRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup("Dev Switcher") {
            // 画面と終了処理で同じ `AppState` を使う。
            // 表示のタイミングで結び付けると、その前に来た終了要求が
            // 直列化と手掛かりの保存を素通りする。
            RootView()
                .environment(appDelegate.appState)
        }
        .defaultSize(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// アプリ終了をサービス停止の意思表示とは扱わないため、終了時のプロセス破棄は行わない。
/// 代わりに、次回の再検証に使う手掛かりを終了直前に書き出す。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 生成時から保持する。あとから結び付ける形にすると、
    /// 結び付く前の終了要求が `.terminateNow` になり、保存を飛ばしてしまう。
    let appState = AppState()
    private lazy var termination = TerminationCoordinator(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 錨は同定の根拠になるため、できるだけ終了直前に測り直す。
    /// 判断そのものは `TerminationCoordinator` にあり、テストで確かめている。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.shouldTerminate { canTerminate in
            NSApp.reply(toApplicationShouldTerminate: canTerminate)
        }
    }
}
