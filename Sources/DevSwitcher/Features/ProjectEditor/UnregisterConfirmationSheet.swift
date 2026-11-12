import DevSwitcherCore
import SwiftUI

/// 登録解除の確認。
///
/// 破壊的に見える操作なので、何が消えて何が消えないのかを実行前に断言する。
/// 破壊的な選択肢を既定ボタンにしない（`docs/SPEC.md` 16.2 I-6）。⏎ では実行しない。
struct UnregisterConfirmationSheet: View {
    @Environment(AppState.self) private var state
    let presentation: AppState.UnregisterPresentation

    @State private var errorMessage: String?

    private var project: ProjectDefinition { presentation.project }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("「\(project.name)」の登録を解除しますか？")
                .font(Typography.title)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Dev Switcher の一覧から外すだけです。次のディレクトリとその中身は削除されません。")
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(project.workingDirectories) { workingDirectory in
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(workingDirectory.name)
                            .font(Typography.support.weight(.semibold))
                        Text(workingDirectory.directory.path)
                            .font(Typography.mono)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("登録しているプロセス \(project.services.count) 件とスタック \(project.managedStacks.count) 件の設定は失われます。")
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.support)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // 既定は安全側。⏎ は「キャンセル」に当たる。
                Button("キャンセル", role: .cancel) {
                    state.unregisterPresentation = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("登録を解除", role: .destructive) { unregister() }
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
    }

    private func unregister() {
        do {
            try state.unregisterProject(project)
        } catch {
            // 失敗したらシートを閉じない。解除できたと誤認させない。
            errorMessage = "登録を解除できませんでした。設定ファイルと一覧は変更していません。\n\(error)"
        }
    }
}
