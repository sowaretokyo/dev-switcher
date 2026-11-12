import Foundation
import Testing
@testable import DevSwitcherApp

@Suite("アプリの更新設定")
struct UpdateConfigurationTests {
    private var releaseInfo: [String: Any] {
        [
            "DevSwitcherUpdatesEnabled": true,
            "SUFeedURL": "https://github.com/sowaretokyo/dev-switcher/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
    }

    @Test("SwiftPM 直接起動とローカル配布物は更新サーバーへ接続しない")
    func developmentBuilds() throws {
        #expect(try !UpdateConfiguration.isEnabled(info: [:], isAppBundle: false))
        #expect(try !UpdateConfiguration.isEnabled(
            info: ["DevSwitcherUpdatesEnabled": false], isAppBundle: true
        ))
    }

    @Test("配布アプリは HTTPS と Ed25519 公開鍵を必要とする")
    func validRelease() throws {
        #expect(try UpdateConfiguration.isEnabled(info: releaseInfo, isAppBundle: true))
    }

    @Test("配布アプリの必須キー欠落を無効扱いにしない", arguments: [
        "DevSwitcherUpdatesEnabled", "SUFeedURL", "SUPublicEDKey"
    ])
    func missingReleaseConfiguration(key: String) {
        var info = releaseInfo
        info.removeValue(forKey: key)
        #expect(throws: UpdateConfiguration.ConfigurationError.self) {
            try UpdateConfiguration.isEnabled(info: info, isAppBundle: true)
        }
    }

    @Test("安全でない更新先を拒否する", arguments: [
        "http://example.com/appcast.xml", "file:///tmp/appcast.xml",
        "https:///", "https://user:password@example.com/appcast.xml", ""
    ])
    func invalidFeed(feed: String) {
        var info = releaseInfo
        info["SUFeedURL"] = feed
        #expect(throws: UpdateConfiguration.ConfigurationError.self) {
            try UpdateConfiguration.isEnabled(info: info, isAppBundle: true)
        }
    }

    @Test("欠けた公開鍵や不正な公開鍵を拒否する", arguments: [
        "", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()
    ])
    func invalidKey(key: String) {
        var info = releaseInfo
        info["SUPublicEDKey"] = key
        #expect(throws: UpdateConfiguration.ConfigurationError.self) {
            try UpdateConfiguration.isEnabled(info: info, isAppBundle: true)
        }
    }
}
