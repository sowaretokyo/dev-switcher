import Foundation

enum AppResources {
    static let bundleName = "DevSwitcher_DevSwitcherApp"

    /// 配布アプリは同梱物だけを使う。欠落を開発マシンのビルド先で補わない。
    static func bundle(for application: Bundle = .main) throws -> Bundle {
        guard application.bundleURL.pathExtension == "app" else {
            // swift run / swift test はSwiftPMの配置を使う。
            return .module
        }
        guard let url = application.url(forResource: bundleName, withExtension: "bundle"),
              let resources = Bundle(url: url) else {
            throw ResourceError.missingBundle(application.bundleURL)
        }
        return resources
    }

    enum ResourceError: Error, CustomStringConvertible {
        case missingBundle(URL)

        var description: String {
            switch self {
            case let .missingBundle(url):
                "アプリの同梱リソースが見つかりません。アプリを入れ直してください。\n\(url.path)"
            }
        }
    }
}
