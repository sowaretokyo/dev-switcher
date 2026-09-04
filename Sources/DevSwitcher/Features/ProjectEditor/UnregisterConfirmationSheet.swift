import DevSwitcherCore
import SwiftUI

/// 登録解除の確認。
///
/// 破壊的に見える操作なので、何が消えて何が消えないのかを実行前に断言する。
/// 破壊的な選択肢を既定ボタンにしない（DESIGN.md I-6）。⏎ では実行しない。
struct UnregisterConfirmationSheet: View {
    @Environment(AppState.self) private var state
    let presentation: AppState.UnregisterPresentation

    @State private var errorMessage: String?

    private var project: ProjectDefinition { presentation.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("「\(project.name)」の登録を解除しますか？")
                .font(.system(size: 13.5, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Dev Switcher の一覧から外すだけです。次のディレクトリとその中身は削除されません。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(project.directory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(project.directory.path) は削除されません。ローカルのリポジトリ、ファイル、ログはそのまま残ります。")
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("登録しているサービス \(project.services.count) 件の設定は失われます。もう一度使うには登録し直してください。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
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
        .padding(20)
        .frame(width: 452)
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
