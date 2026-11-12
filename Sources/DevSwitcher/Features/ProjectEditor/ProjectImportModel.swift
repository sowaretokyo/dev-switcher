import DevSwitcherCore
import Foundation
import Observation

/// ファイル読み込みと確認内容を管理する。検証・保存の可否はAppStateが判断する。
@MainActor
@Observable
final class ProjectImportModel {
    struct Preview {
        let projects: [ProjectDefinition]
        let json: String
    }

    private(set) var preview: Preview?
    private(set) var fileName: String?
    var errorMessage: String?

    /// 未選択と読み込み失敗では、追加できる開発環境が0件になる。
    var projectCount: Int { preview?.projects.count ?? 0 }

    func read(
        _ result: Result<URL, any Error>,
        validate: (Data, String) throws -> [ProjectDefinition]
    ) {
        // 次の読み込みが失敗した場合、以前の確認内容を追加できないよう先に破棄する。
        preview = nil
        errorMessage = nil
        fileName = nil
        do {
            let url = try result.get()
            fileName = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let projects = try validate(Data(contentsOf: url), url.path)
            let data = try ProjectsDocument(projects: projects).jsonData()
            preview = Preview(projects: projects, json: String(decoding: data, as: UTF8.self))
        } catch {
            errorMessage = L10n.text("取り込めません。\n\(error)")
        }
    }

    static func creationGuide(language: AppLocalization.Language = AppLocalization.selectedLanguage) throws -> String {
        let resources = try AppResources.bundle()
        let guideName = language == .japanese ? "ProjectImportGuide" : "ProjectImportGuide.en"
        guard let guideURL = resources.url(forResource: guideName, withExtension: "md"),
              let exampleURL = resources.url(forResource: "ProjectImportExample", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let example = try String(contentsOf: exampleURL, encoding: .utf8)
        let localization = try AppLocalization(language: language, resources: resources)
        return guide + localization.render("\n\n## サンプル\n\n```json\n") + example + "\n```\n"
    }
}
