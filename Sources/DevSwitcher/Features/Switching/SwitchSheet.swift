import DevSwitcherCore
import SwiftUI

/// 停止を伴う切替のシート。
///
/// ポート解放ゲートの進捗と、起動フェーズ前だけ受け付ける中止のためのUI。
/// 多重操作を止めているのは `AppState` の `ActivityToken` であり、このシートではない
/// （`docs/SPEC.md` 16.2 I-1）。単純な起動・停止では出さない。
struct SwitchSheet: View {
    @Environment(AppState.self) private var state
    /// 提示された時点の値。同一性の判定にだけ使う。
    let initialPresentation: AppState.SwitchPresentation

    /// 進行状態は`AppState`から読む。シートへ値を渡し切りにすると、
    /// ゲートの進捗が更新されないまま止まって見える。
    private var presentation: AppState.SwitchPresentation {
        state.switchPresentation ?? initialPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(title)
                .font(Typography.title)

            VStack(alignment: .leading, spacing: Spacing.s) {
                StageRow(
                    label: L10n.text("\(presentation.sourceName) を停止"),
                    status: stopStatus,
                    detail: stopDetail
                )
                // ゲートは「切替元が実際に握っていたポートの解放」だけ（I-3）。
                // 切替先の設定ポートは調べない。取得できるかは OS が決める。
                GateBox(
                    rows: [
                        GateBox.Row(
                            label: L10n.text("\(presentation.sourceName) のポートが解放された"),
                            status: releaseStatus,
                            counter: releaseCounter
                        ),
                    ]
                )
                StageRow(
                    label: L10n.text("\(presentation.targetName) を起動"),
                    status: startStatus,
                    detail: startDetail
                )
            }

            Divider()

            if presentation.canCancel {
                Text(L10n.text("中止すると、\(presentation.sourceName)の停止は最後まで実行し、\(presentation.targetName)は起動しません。"))
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("起動フェーズに入ったため、中止は受け付けられません。送出済みの停止処理を取り消せないためです。"))
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                ProgressView().controlSize(.small)
                Text(presentation.state.label)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("切替を中止")) {
                    state.cancelSwitch()
                }
                .disabled(!presentation.canCancel)
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.sheetWidth)
        .interactiveDismissDisabled()
    }

    private var title: String {
        L10n.text("「\(presentation.sourceName)」から「\(presentation.targetName)」へ切り替えています")
    }

    private var stopStatus: StageStatus {
        switch presentation.state {
        case .idle: .pending
        case .stopping: .inProgress
        default: .done
        }
    }

    private var stopDetail: String? {
        if case let .stopping(service, index, total) = presentation.state {
            return L10n.text("\(service)（\(index)/\(total)）")
        }
        return nil
    }

    private var releaseStatus: StageStatus {
        switch presentation.state {
        case .idle, .stopping: .pending
        case .verifyingRelease: .inProgress
        default: .done
        }
    }

    private var releaseCounter: String? {
        if case let .verifyingRelease(released, total) = presentation.state {
            return "\(released)/\(total)"
        }
        return nil
    }

    private var startStatus: StageStatus {
        switch presentation.state {
        case .starting, .observingStartup, .rollingBack: .inProgress
        case .completed: .done
        default: .pending
        }
    }

    private var startDetail: String? {
        switch presentation.state {
        case let .starting(service, index, total): L10n.text("\(service)（\(index)/\(total)）")
        case let .observingStartup(service): L10n.text("\(service) の起動を確認")
        case let .rollingBack(service): L10n.text("\(service) を停止（巻き戻し）")
        default: nil
        }
    }
}

enum StageStatus {
    case pending
    case inProgress
    case done

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: .accentColor
        case .done: .green
        }
    }
}

struct StageRow: View {
    let label: String
    let status: StageStatus
    var detail: String?

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: status.symbol)
                .font(.system(size: Metrics.stageIcon))
                .foregroundStyle(status.tint)
            Text(label)
                .font(Typography.row)
            if let detail {
                Text(detail)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// ゲートの検証をひとまとまりで見せる。進捗は数で出す。
struct GateBox: View {
    struct Row: Identifiable {
        let label: String
        let status: StageStatus
        let counter: String?

        var id: String { label }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(rows) { row in
                HStack(spacing: Spacing.s) {
                    Image(systemName: row.status.symbol)
                        .font(.system(size: Metrics.stageIcon))
                        .foregroundStyle(row.status.tint)
                    Text(row.label)
                        .font(Typography.row)
                    Spacer()
                    if let counter = row.counter {
                        Text(counter)
                            .font(Typography.mono)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
