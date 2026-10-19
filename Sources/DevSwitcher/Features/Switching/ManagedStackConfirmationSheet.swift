import DevSwitcherCore
import SwiftUI

/// 既存スタックの引き継ぎ・復旧・停止を、1つのシートで確認する。
///
/// 引き継ぐ対象と停止する全対象を分割せず並べる（`docs/SPEC.md` 6.3、6.4）。
/// 破壊的な操作を既定にせず、キャンセルを既定選択にする。
struct ManagedStackConfirmationSheet: View {
    @Environment(AppState.self) private var state
    let presentation: AppState.ManagedStackConfirmationPresentation

    private var content: ConfirmationSheetContent { ConfirmationSheetContent(plan: presentation.plan) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(presentation.title)
                .font(Typography.title)

            Text(content.lead)
                .font(Typography.row)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionLabel("対象のスタック")
                ForEach(content.rows) { row in
                    StackRow(row: row)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(content.notes, id: \.self) { note in
                    NoteText(note, tint: .secondary)
                }
            }

            Divider()

            HStack {
                Button(
                    presentation.confirmButtonTitle,
                    role: presentation.isDestructive ? .destructive : nil
                ) {
                    state.approveManagedStackConfirmation(presentation)
                }
                Spacer()
                Button("キャンセル") {
                    state.cancelManagedStackConfirmation()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
    }
}

private struct StackRow: View {
    let row: ConfirmationSheetContent.Row

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(row.identity)
                    .font(Typography.mono)
                    .textSelection(.enabled)
                Text(row.registration)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                if let path = row.configDirectory {
                    Text(path)
                        .font(Typography.monoSmall)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Spacing.s)
            VStack(alignment: .trailing, spacing: Spacing.hairline) {
                Text(row.state)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                Text(row.action)
                    .font(Typography.heading)
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
