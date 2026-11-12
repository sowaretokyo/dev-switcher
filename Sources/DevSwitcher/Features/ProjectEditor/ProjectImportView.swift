import AppKit
import DevSwitcherCore
import SwiftUI
import UniformTypeIdentifiers

/// 読み込みはプレビューまで。保存は利用者が確認した後にAppStateで一括実行する。
struct ProjectImportView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFile = false
    @State private var model = ProjectImportModel()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(L10n.text("JSONから開発環境を取り込む"))
                    .font(Typography.title)
                Text(L10n.text("内容を確認して、新しい開発環境として一括追加します。既存設定の上書きやプロセスの起動は行いません。"))
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("JSONファイルを選択…")) { isChoosingFile = true }
                    if let fileName = model.fileName {
                        Text(fileName)
                            .font(Typography.support)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button(L10n.text("AI向けの作成ガイドをコピー")) { copyGuide() }
                    .font(Typography.support)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let preview = model.preview {
                        Text(L10n.text("開発環境 \(preview.projects.count) 件・プロセス \(preview.projects.reduce(0) { $0 + $1.services.count }) 件・スタック \(preview.projects.reduce(0) { $0 + $1.managedStacks.count }) 件"))
                            .font(Typography.support.weight(.semibold))
                        ForEach(preview.projects) { project in
                            projectPreview(project)
                        }
                        DisclosureGroup(L10n.text("設定の全項目を確認")) {
                            Text(preview.json)
                                .font(Typography.monoSmall)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(L10n.text("Dev Switcherの設定形式のJSONを選択してください。開発環境名やIDが登録済みの設定と重複している場合は取り込めません。"))
                            .font(Typography.support)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(Typography.support)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.l)
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                if let reason = state.configurationBlockedReason {
                    Text(reason)
                        .font(Typography.support)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("キャンセル"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.text("\(model.projectCount)件を追加")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.projectCount == 0 || !state.canChangeConfiguration)
                }
            }
            .padding(Spacing.l)
        }
        .frame(width: Metrics.editorSheetWidth, height: Metrics.editorSheetHeight)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.json]) { result in
            model.read(result, validate: state.previewProjectImport)
        }
    }

    private func projectPreview(_ project: ProjectDefinition) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                ProjectChip(project: project)
                Text(project.name).font(Typography.support.weight(.semibold))
            }
            ForEach(project.workingDirectories) { directory in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(directory.name)
                    Text(directory.directory.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(Typography.support)
            }
            Text(L10n.text("スタック・プロセスの起動順"))
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            ForEach(ProjectValidator.warnings(project).map(\.description), id: \.self) { warning in
                Text(warning).font(Typography.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = project.migrationNotice {
                Text(notice).font(Typography.caption).foregroundStyle(.orange)
            }
            ForEach(Array(project.launchUnits.enumerated()), id: \.element.id) { index, service in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(L10n.text("\(index + 1). \(service.name)（\(project.isEnabledNow(service.id) ? L10n.text("起動対象") : L10n.text("対象外"))）"))
                    Text(service.commandDescription)
                        .font(Typography.monoSmall)
                        .textSelection(.enabled)
                    Text(service.workingDirectory.path)
                        .foregroundStyle(.secondary)
                }
                .font(Typography.support)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .cardBackground()
    }

    private func save() {
        do {
            guard let preview = model.preview else { throw ProjectStoreError.emptyImport }
            try state.importProjects(preview.projects)
            dismiss()
        } catch {
            model.errorMessage = L10n.text("追加できませんでした。設定ファイルと一覧は変更していません。\n\(error)")
        }
    }

    private func copyGuide() {
        do {
            let guide = try ProjectImportModel.creationGuide()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(guide, forType: .string) else {
                model.errorMessage = L10n.text("作成ガイドをクリップボードにコピーできませんでした。")
                return
            }
            model.errorMessage = nil
        } catch {
            model.errorMessage = L10n.text("作成ガイドを読み込めません。\n\(error)")
        }
    }
}
