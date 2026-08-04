import DevSwitcherCore
import SwiftUI

/// 切替中のシート。
///
/// 表示中はサイドバーへイベントが届かない。無効化ではなくモーダルで遮ることが
/// 「切替中に次を起動しない」の実体（DESIGN.md I-1）。
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
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                if let sourceName = presentation.sourceName {
                    StageRow(
                        label: "\(sourceName) を停止",
                        status: stopStatus,
                        detail: stopDetail
                    )
                }
                // ゲートは2つの独立した検証なので2行で出す（I-3）。
                GateBox(
                    rows: [
                        GateBox.Row(
                            label: presentation.sourceName.map { "\($0) のポートが解放された" }
                                ?? "停止元のポート解放",
                            status: releaseStatus,
                            counter: releaseCounter
                        ),
                        GateBox.Row(
                            label: presentation.targetName.map { "\($0) のポートを確認" }
                                ?? "起動先のポート確認",
                            status: acquireStatus,
                            counter: acquireCounter
                        ),
                    ]
                )
                if let targetName = presentation.targetName {
                    StageRow(
                        label: "\(targetName) を起動",
                        status: startStatus,
                        detail: startDetail
                    )
                }
            }

            Divider()

            if presentation.canCancel {
                Text("中止すると、\(presentation.sourceName ?? "切替元")の停止は最後まで実行し、\(presentation.targetName ?? "切替先")は起動しません。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("起動フェーズに入ったため、中止は受け付けられません。送出済みの停止処理を取り消せないためです。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                ProgressView().controlSize(.small)
                Text(presentation.state.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("切替を中止") {
                    state.cancelSwitch()
                }
                .disabled(!presentation.canCancel)
            }
        }
        .padding(20)
        .frame(width: 452)
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch (presentation.sourceName, presentation.targetName) {
        case let (source?, target?): "「\(source)」から「\(target)」へ切り替えています"
        case let (nil, target?): "「\(target)」を起動しています"
        case let (source?, nil): "「\(source)」を停止しています"
        case (nil, nil): "処理中"
        }
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
            return "\(service)（\(index)/\(total)）"
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

    private var acquireStatus: StageStatus {
        switch presentation.state {
        case .idle, .stopping, .verifyingRelease: .pending
        case .verifyingAcquire: .inProgress
        default: .done
        }
    }

    private var acquireCounter: String? {
        if case let .verifyingAcquire(free, total) = presentation.state {
            return "\(free)/\(total)"
        }
        return nil
    }

    private var startStatus: StageStatus {
        switch presentation.state {
        case .starting, .awaitingHealth, .rollingBack: .inProgress
        case .completed: .done
        default: .pending
        }
    }

    private var startDetail: String? {
        switch presentation.state {
        case let .starting(service, index, total): "\(service)（\(index)/\(total)）"
        case let .awaitingHealth(service): "\(service) のヘルスチェックを待機"
        case let .rollingBack(service): "\(service) を停止（巻き戻し）"
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
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 11))
                .foregroundStyle(status.tint)
            Text(label)
                .font(.system(size: 12))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// 2つのゲート検証をひとまとまりで見せる。進捗は数で出す。
struct GateBox: View {
    struct Row: Identifiable {
        let label: String
        let status: StageStatus
        let counter: String?

        var id: String { label }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.status.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(row.status.tint)
                    Text(row.label)
                        .font(.system(size: 12))
                    Spacer()
                    if let counter = row.counter {
                        Text(counter)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
