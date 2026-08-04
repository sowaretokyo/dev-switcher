import DevSwitcherCore
import SwiftUI

/// アプリ再起動時に既存プロセスを検出したときのシート。
///
/// 選べるのは「引き継ぐ」「すべて停止」「無視」。無視してもポートは埋まったままなので、
/// 次の切替はゲートが止める（DESIGN.md 決定 e）。
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

    @State private var isConfirmingStopAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("既存のプロセスを検出しました")
                .font(.system(size: 13.5, weight: .semibold))

            Text("前回 Dev Switcher が起動したプロセスの手掛かりを、実際のプロセスと照合しました。開始時刻・実行ファイル・作業ディレクトリ・listen ポートがすべて一致したものだけを引き継ぎ候補にしています。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !review.candidates.isEmpty {
                        section("引き継げる候補") {
                            ForEach(review.candidates) { candidate in
                                CandidateRow(candidate: candidate)
                            }
                        }
                    }

                    // 引き継げないが資源を握っているものを黙って捨てない。
                    // 停止手段を出さないと、GUI から復旧できないプロセスが残る。
                    if !review.stoppable.isEmpty {
                        section("引き継げないが停止できるもの") {
                            ForEach(review.stoppable) { finding in
                                StoppableRow(finding: finding)
                            }
                        }
                    }

                    if !review.rejected.isEmpty {
                        section("対象にしないもの") {
                            ForEach(Array(review.rejected.enumerated()), id: \.offset) { _, record in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(record.serviceName)（PID \(record.processID)）")
                                        .font(.system(size: 12))
                                    Text(record.reason.description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("「無視」を選んでもプロセスやポートが残る可能性があります。残っている場合、次の切替はゲートが止めます。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                if hasStoppable {
                    // 破壊的な選択肢は既定ボタンにしない（I-6）。
                    Button("すべて停止") {
                        isConfirmingStopAll = true
                    }
                    .foregroundStyle(.red)
                }
                if let description = live.resolvingDescription {
                    // 実行中であることを黙らせない。二重操作は AppState が拒否するが、
                    // 何が起きているか分からないまま押させない。
                    ProgressView().controlSize(.small)
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("無視") {
                    // 破棄できたときだけ AppState がシートを閉じる。失敗したまま閉じると、
                    // 無視したはずの手掛かりが次回も出てくる理由が分からなくなる。
                    state.performHandoffAction(.ignore, presentationID: live.id)
                }
                // 引き継げるものが無い場合、既定は安全側の「無視」に倒す。
                .keyboardShortcut(review.candidates.isEmpty ? .defaultAction : .cancelAction)
                if !review.candidates.isEmpty {
                    Button("引き継ぐ") {
                        state.performHandoffAction(.adopt, presentationID: live.id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            // 決着処理の実行中は、この判断に対する操作を一切受け付けない。
            .disabled(live.isResolving)
        }
        .padding(20)
        .frame(width: 452)
        // 選択せずに閉じられると、引き継ぎも停止もしないまま再表示する導線が無くなる。
        .interactiveDismissDisabled()
        .confirmationDialog(
            "検出したプロセスを停止しますか？",
            isPresented: $isConfirmingStopAll,
            titleVisibility: .visible
        ) {
            // シートの開閉は AppState が決める。ここで閉じると、
            // 失敗したときの再提示と競合して、やり直せなくなる。
            Button("停止する", role: .destructive) {
                state.performHandoffAction(.stopAll, presentationID: live.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(stopConfirmationMessage)
        }
    }

    private var hasStoppable: Bool {
        !review.candidates.isEmpty || !review.stoppable.isEmpty
    }

    private var stopConfirmationMessage: String {
        let names = (review.candidates.map(\.hint.serviceName)
            + review.stoppable.map(\.hint.serviceName))
            .joined(separator: " / ")
        return """
            次のサービスへ通常終了（SIGTERM）を送ります。

            \(names)

            送信の直前に、記録したプロセスと同一かを再検証します。一致しない場合は送信しません。
            """
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 引き継げないが停止はできるプロセス。なぜ引き継げないのかを必ず添える。
private struct StoppableRow: View {
    let finding: StoppableProcessFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(finding.hint.serviceName)
                    .font(.system(size: 12, weight: .semibold))
                Text(evidenceLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(finding.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var evidenceLabel: String {
        switch finding.evidence {
        case let .matchedLeader(identity):
            "PID \(identity.pid)"
        case let .verifiedGroup(livePIDs):
            "PGID \(finding.hint.processGroupID) / 残り "
                + livePIDs.map(String.init).joined(separator: ", ")
        }
    }
}

private struct CandidateRow: View {
    let candidate: HandoffCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(candidate.hint.serviceName)
                    .font(.system(size: 12, weight: .semibold))
                Text("PID \(candidate.identity.pid)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(portSummary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(candidate.identity.workingDirectory.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// 表示するのは実測ポート。保存値ではない。
    private var portSummary: String {
        guard !candidate.observedPorts.isEmpty else { return "listen ポートなし" }
        return candidate.observedPorts.map { ":\($0.port)" }.joined(separator: " · ")
    }
}
