import AppKit
import Combine
import DevSwitcherCore
import Sparkle
import SwiftUI

/// SwiftPM の直接起動と、更新機能を明示的に無効にしたローカル配布物を区別する。
/// 配布アプリの設定欠落は、更新機能を黙って無効にせずエラーにする。
enum UpdateConfiguration {
    static func isEnabled(info: [String: Any], isAppBundle: Bool) throws -> Bool {
        guard isAppBundle else { return false }
        guard let enabled = info["DevSwitcherUpdatesEnabled"] as? Bool else {
            throw ConfigurationError.invalid("DevSwitcherUpdatesEnabled")
        }
        guard enabled else { return false }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ConfigurationError.invalid("SUFeedURL")
        }
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else {
            throw ConfigurationError.invalid("SUPublicEDKey")
        }
        return true
    }

    enum ConfigurationError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let key):
                L10n.text("アプリの更新設定が不正です（\(key)）。配布元からアプリを入れ直してください。")
            }
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isEnabled = false
    private var controller: SPUStandardUpdaterController?
    private var configurationError: Error?
    private var didStart = false

    func start(bundle: Bundle = .main) {
        precondition(!didStart, "The updater must be started only once")
        didStart = true
        do {
            let enabled = try UpdateConfiguration.isEnabled(
                info: bundle.infoDictionary ?? [:],
                isAppBundle: bundle.bundleURL.pathExtension == "app"
            )
            guard enabled else { return }
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
            )
            self.controller = controller
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .assign(to: &$automaticallyChecksForUpdates)
            isEnabled = true
        } catch {
            configurationError = error
            showMessage(error.localizedDescription)
        }
    }

    func checkForUpdates() {
        if let configurationError {
            showMessage(configurationError.localizedDescription)
        } else if let controller {
            controller.checkForUpdates(nil)
        } else {
            showMessage(L10n.text("開発用ビルドでは更新を確認できません。配布版の Dev Switcher を使用してください。"))
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        precondition(isEnabled && controller != nil, "Updater settings require a running updater")
        controller!.updater.automaticallyChecksForUpdates = enabled
    }

    private func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text("アップデートを確認できません。")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("閉じる"))
        alert.runModal()
    }
}

struct AppUpdateMenu: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button(L10n.text("アップデートを確認…"), action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
        Toggle(L10n.text("アップデートを自動確認"), isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        ))
        .disabled(!updater.isEnabled)
    }
}
