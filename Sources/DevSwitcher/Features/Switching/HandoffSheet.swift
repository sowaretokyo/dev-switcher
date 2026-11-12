import DevSwitcherCore
import SwiftUI

/// アプリ再起動時に既存プロセスを検出したときのシート。
///
/// 通常の選択肢は「停止する」「そのまま使う」の2つだけ。
/// 安全に再利用できない残存では「そのまま使う」の代わりに「停止しない」を出す。
/// 一致しなかった候補も理由つきで出す。黙って捨てると、なぜ引き継がれないのか分からない。
struct HandoffSheet: View {
    @Environment(AppState.self) private var state
    /// 提示された時点の値。同一性の判定と、差し替え直後の描画にだけ使う。
    let presentation: AppState.HandoffPresentation

    /// 進行状態は`AppState`から読む。渡し切りにすると、実行中でもボタンが押せてしまう。
    private var live: AppState.HandoffPresentation {
        state.handoffPresentation ?? presentation
    }

    private var review: HandoffReview { live.review }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(L10n.text("プロセスが動いています"))
                .font(Typography.title)

            Text(L10n.text("前回 Dev Switcher が起動したプロセスを確認しました。停止するか、そのまま使うか選んでください。"))
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if !review.candidates.isEmpty {
                        section(L10n.text("そのまま使えるプロセス")) {
                            ForEach(review.candidates) { candidate in
                                CandidateRow(candidate: candidate)
                            }
                        }
                    }

                    // 引き継げないが資源を握っているものを黙って捨てない。
                    // 停止手段を出さないと、GUI から復旧できないプロセスが残る。
                    if !review.stoppable.isEmpty {
                        section(L10n.text("停止が必要なプロセス")) {
                            ForEach(review.stoppable) { finding in
                                StoppableRow(finding: finding)
                            }
                        }
                    }

                    if !review.rejected.isEmpty {
                        section(L10n.text("操作できないプロセス")) {
                            ForEach(Array(review.rejected.enumerated()), id: \.offset) { _, record in
                                VStack(alignment: .leading, spacing: Spacing.hairline) {
                                    Text(L10n.text("\(record.serviceName)（PID \(record.processID)）"))
                                        .font(Typography.row)
                                    Text(record.reason.description)
                                        .font(Typography.support)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: Metrics.handoffListMaxHeight)

            Divider()

            HStack {
                if hasStoppable {
                    // このシート自体が停止前の確認。確認を二重に重ねない。
                    Button(L10n.text("停止する"), role: .destructive) {
                        state.performHandoffAction(.stopAll, presentationID: live.id)
                    }
                }
                if let description = live.resolvingDescription {
                    // 実行中であることを黙らせない。二重操作は AppState が拒否するが、
                    // 何が起きているか分からないまま押させない。
                    ProgressView().controlSize(.small)
                    Text(description)
                        .font(Typography.support)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if review.candidates.isEmpty {
                    Button(L10n.text("停止しない")) {
                        // 破棄できたときだけ AppState がシートを閉じる。
                        state.performHandoffAction(.ignore, presentationID: live.id)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text("そのまま使う")) {
                        state.performHandoffAction(.adopt, presentationID: live.id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            // 決着処理の実行中は、この判断に対する操作を一切受け付けない。
            .disabled(live.isResolving)
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
        // 選択せずに閉じられると、引き継ぎも停止もしないまま再表示する導線が無くなる。
        .interactiveDismissDisabled()
    }

    private var hasStoppable: Bool {
        !review.candidates.isEmpty || !review.stoppable.isEmpty
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title)
                .font(Typography.sectionLabel)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// 引き継げないが停止はできるプロセス。なぜ引き継げないのかを必ず添える。
private struct StoppableRow: View {
    let finding: StoppableProcessFinding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            HStack(spacing: Spacing.s) {
                Text(finding.hint.serviceName)
                    .font(Typography.heading)
                Text(evidenceLabel)
                    .font(Typography.monoSmall)
                    .foregroundStyle(.secondary)
            }
            Text(finding.reason)
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var evidenceLabel: String {
        switch finding.evidence {
        case let .matchedLeader(identity):
            "PID \(identity.pid)"
        case let .verifiedGroup(livePIDs):
            L10n.text("PGID \(finding.hint.processGroupID) / 残り ")
                + livePIDs.map(String.init).joined(separator: ", ")
        }
    }
}

private struct CandidateRow: View {
    let candidate: HandoffCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            HStack(spacing: Spacing.s) {
                Text(candidate.hint.serviceName)
                    .font(Typography.heading)
                Text("PID \(candidate.identity.pid)")
                    .font(Typography.monoSmall)
                    .foregroundStyle(.secondary)
            }
            Text(portSummary)
                .font(Typography.monoSmall)
                .foregroundStyle(.secondary)
            Text(candidate.identity.workingDirectory.path)
                .font(Typography.monoSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// 表示するのは実測ポート。保存値ではない。
    private var portSummary: String {
        guard !candidate.observedPorts.isEmpty else { return L10n.text("listen ポートなし") }
        return candidate.observedPorts.map { ":\($0.port)" }.joined(separator: " · ")
    }
}
