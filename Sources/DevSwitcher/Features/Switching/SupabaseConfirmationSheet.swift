import DevSwitcherCore
import SwiftUI

/// 既存Supabaseスタックの引き継ぎ・復旧・停止を、1つのシートで確認する。
///
/// 引き継ぐ対象と停止する全対象を分割せず並べる（`MVP_SPEC.md` 6.1.1）。
/// 破壊的な操作を既定にせず、キャンセルを既定選択にする。
struct SupabaseConfirmationSheet: View {
    @Environment(AppState.self) private var state
    let presentation: AppState.SupabaseConfirmationPresentation

    private var plan: SupabaseConfirmationPlan { presentation.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(presentation.title)
                .font(Typography.title)

            Text("開発環境「\(plan.projectName)」のサービス「\(plan.serviceName)」を起動する前に、既存のローカルSupabaseスタックの扱いを決めてください。")
                .font(Typography.row)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionLabel("対象のスタック")
                ForEach(plan.allTargets) { target in
                    StackRow(target: target)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(notes, id: \.self) { note in
                    NoteText(note, tint: .secondary)
                }
            }

            Divider()

            HStack {
                Button(
                    presentation.confirmButtonTitle,
                    role: presentation.isDestructive ? .destructive : nil
                ) {
                    state.approveSupabaseConfirmation(presentation)
                }
                Spacer()
                Button("キャンセル") {
                    state.cancelSupabaseConfirmation()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
    }

    /// 何が起き、何が起きないかを明示する。既定へ倒した挙動を黙って実行しない。
    private var notes: [String] {
        var notes: [String] = []
        switch plan.target.action {
        case .adopt:
            notes.append("引き継いだあとは、Dev Switcherから停止・切替できます。")
            notes.append("現在のスタックへ起動コマンドの `--exclude` などは再適用しません。")
        case .restart:
            notes.append("対象の `project_id` だけを停止し、停止を確認してから起動し直します。")
        case .start, .stop:
            notes.append("対象は新しく起動します。")
        }
        if !plan.stopTargets.isEmpty {
            notes.append("停止は `project_id` を1件ずつ指定して実行します（`--all` と `--no-backup` は使いません）。")
            notes.append("停止後に対象の起動が失敗しても、停止したスタックは自動で再起動しません。")
        }
        notes.append("キャンセルした場合、既存スタック・切替元・切替先のいずれも変更しません。")
        return notes
    }
}

private struct StackRow: View {
    let target: SupabaseConfirmationTarget

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(target.projectID.rawValue)
                    .font(Typography.mono)
                    .textSelection(.enabled)
                Text(registrationText)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                if let path = target.registration?.configDirectory.path {
                    Text(path)
                        .font(Typography.monoSmall)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Spacing.s)
            VStack(alignment: .trailing, spacing: Spacing.hairline) {
                Text(target.state.label)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                Text(target.action.label)
                    .font(Typography.heading)
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var registrationText: String {
        guard let registration = target.registration else { return "未登録" }
        return "\(registration.projectName) / \(registration.serviceName)"
    }
}
