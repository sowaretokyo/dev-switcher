import DevSwitcherCore
import SwiftUI

/// 切替失敗のシート。
///
/// 必ず「現在の状態」を書く（`docs/SPEC.md` 16.2 I-5）。両方のプロジェクトが今どうなっているかを
/// 断言しないと、利用者は次に何をすればよいか決められない。
/// 破壊的な選択肢は既定ボタンにしない（I-6）。
struct SwitchFailureSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let presentation: AppState.FailurePresentation

    @State private var isConfirmingForceStop = false

    private var failure: SwitchFailure { presentation.failure }

    /// 通常終了で止まらなかったサービス。強制終了の対象になる。
    private var stopFailures: [StopFailureDetail] {
        if case let .stopFailed(services) = failure.reason { return services }
        return []
    }

    /// 停止元プロジェクト。強制終了の対象を特定するために使う。
    private var sourceProject: ProjectDefinition? {
        failure.facts.source.flatMap { state.project($0.projectID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(failure.reason.title)
                .font(Typography.title)

            Text(failure.reason.detail)
                .font(Typography.row)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            currentState

            if case let .portsNotReleased(holders) = failure.reason {
                holderList(holders)
            }

            if canForceStop {
                Text(L10n.text("通常終了（SIGTERM）では停止できませんでした。強制終了（SIGKILL）は後始末を行わずにプロセスを止めます。実行するか判断してください。"))
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                // 破壊的な選択肢は塗りつぶさず、既定ボタンにもしない（I-6）。
                if canForceStop {
                    Button(L10n.text("強制終了する")) {
                        isConfirmingForceStop = true
                    }
                    .foregroundStyle(.red)
                    .disabled(!state.canStop)
                } else if let activeProject = state.activeProject {
                    Button(L10n.text("残っているプロセスを停止")) {
                        dismiss()
                        state.stopProject(activeProject)
                    }
                    .foregroundStyle(.red)
                    .disabled(!state.canStop)
                }
                if let logTarget = presentation.logTarget {
                    Button(L10n.text("ログを開く")) {
                        // シートを閉じた瞬間に原因のログが目の前にある状態にする。
                        state.openLogTarget(logTarget)
                        dismiss()
                    }
                }
                Spacer()
                // 既定は常に安全側。いまの状態のまま止まる。
                Button(L10n.text("閉じる")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
        // 強制終了の前に必ず再確認する（`docs/SPEC.md` 7、12）。
        .confirmationDialog(
            L10n.text("強制終了しますか？"),
            isPresented: $isConfirmingForceStop,
            titleVisibility: .visible
        ) {
            Button(L10n.text("強制終了する"), role: .destructive) {
                if let sourceProject {
                    state.forceStop(
                        stopFailures.filter { $0.processGroupID != nil },
                        in: sourceProject
                    )
                }
            }
            Button(L10n.text("キャンセル"), role: .cancel) {}
        } message: {
            Text(forceStopConfirmationMessage)
        }
    }

    private var canForceStop: Bool {
        stopFailures.contains { $0.processGroupID != nil } && sourceProject != nil
    }

    /// 何に対して SIGKILL を送るのかを、対象を名指しして示す。
    private var forceStopConfirmationMessage: String {
        let targets = stopFailures.filter { $0.processGroupID != nil }
            .map { detail in
                let group = detail.processGroupID.map { L10n.text("プロセスグループ \($0)") } ?? L10n.text("対象不明")
                return L10n.text("\(detail.serviceName)（\(group)）")
            }
            .joined(separator: "\n")
        return L10n.text("""
            次のプロセスへ SIGKILL を送ります。後始末は行われません。

            \(targets)

            送信の直前に、起動時に記録したプロセスと同一かを再検証します。一致しない場合は送信しません。
            """)
    }

    /// 中途半端な状態を黙って放置しないため、必ず1行ずつ断言する。
    private var currentState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L10n.text("現在の状態"))
                .font(Typography.sectionLabel)
                .foregroundStyle(.tertiary)
            ForEach(Array(failure.facts.statements.enumerated()), id: \.offset) { _, statement in
                Text(statement)
                    .font(Typography.row)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// ポートは番号で名指しする。複数ポートを持つサービスでは名前だけでは原因が分からない。
    /// Dev Switcher の管理外にあるプロセスへ終了操作は出さない。
    private func holderList(_ holders: [ResolvedPortHolder]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L10n.text("占有しているプロセス"))
                .font(Typography.sectionLabel)
                .foregroundStyle(.tertiary)
            ForEach(holders, id: \.pid) { holder in
                Text(holder.description)
                    .font(Typography.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if holders.contains(where: { !$0.ownership.canOfferTermination }) {
                Text(L10n.text("外部プロセス、システムまたは別ユーザーが管理するプロセスには、Dev Switcher から終了操作を提供しません。起動元のターミナルや管理ツールで停止してください。"))
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
