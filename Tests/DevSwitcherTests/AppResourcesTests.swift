import Foundation
import Testing
@testable import DevSwitcherApp

@Suite("配布アプリの同梱リソース")
struct AppResourcesTests {
    @Test("別ディレクトリのアプリに同梱したガイドを読める")
    func loadsResourcesFromApplication() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try makeApplication(in: directory)
        let bundled = app.bundleURL.appendingPathComponent(
            "Contents/Resources/\(AppResources.bundleName).bundle"
        )
        try FileManager.default.copyItem(at: AppResources.bundle().bundleURL, to: bundled)

        let resources = try AppResources.bundle(for: app)
        #expect(resources.bundleURL.standardizedFileURL == bundled.standardizedFileURL)
        let guide = try #require(resources.url(forResource: "ProjectImportGuide", withExtension: "md"))
        let example = try #require(resources.url(forResource: "ProjectImportExample", withExtension: "json"))
        #expect(try String(contentsOf: guide, encoding: .utf8).isEmpty == false)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: example)) is [String: Any])
    }

    @Test("同梱物が欠落したアプリを開発用リソースで補わない")
    func rejectsMissingApplicationResources() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try makeApplication(in: directory)
        #expect(throws: AppResources.ResourceError.self) {
            try AppResources.bundle(for: app)
        }
    }

    private func makeApplication(in directory: URL) throws -> Bundle {
        let url = directory.appendingPathComponent("DevSwitcher.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev-switcher.tests.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return try #require(Bundle(url: url))
    }
}
