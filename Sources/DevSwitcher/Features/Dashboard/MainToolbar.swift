import DevSwitcherCore
import SwiftUI

/// 稼働中、または起動・停止を処理中の開発環境を表示する。
/// 起動・切替の実行は、従来どおり選択中の開発環境の詳細が持つ。
struct ToolbarIdentity: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let project = state.toolbarProject {
            HStack(spacing: Spacing.s) {
                ProjectChip(project: project)
                Text(project.name)
                    .font(Typography.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Metrics.toolbarProjectNameMaxWidth, alignment: .leading)
                    .help(project.name)
                ToolbarProjectStatus(phase: state.phase(of: project))
            }
        } else {
            Text("起動中の開発環境はありません")
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 状態と進捗は同じ領域に出し、操作ボタン側に進捗ラベルを重ねない。
private struct ToolbarProjectStatus: View {
    let phase: ProjectPhase

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Group {
                switch phase {
                case .starting, .stopping, .switching:
                    ProgressView().controlSize(.small)
                case .stopped, .running, .degraded, .failed, .residual:
                    ProjectStatusDot(phase: phase)
                }
            }
            .frame(width: Metrics.chip, height: Metrics.chip)
            Text(phase.label)
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Metrics.toolbarStatusWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.label)
    }
}

/// 操作中もボタンの形と位置を保ち、二重操作は無効化する。
struct ToolbarActions: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let project = state.toolbarProject {
            if project.hasOpenableURLs {
                Menu {
                    ForEach(project.launchUnits) { service in
                        ForEach(service.ports.filter { $0.openURL != nil }) { port in
                            Button("\(service.name) — \(port.displayName)") {
                                state.open(port)
                            }
                        }
                    }
                } label: {
                    Label("開く", systemImage: "arrow.up.forward.app")
                }
                .labelStyle(.titleAndIcon)
                .disabled(state.isOperationInFlight)
                .help("起動中のプロセスの URL を開きます")
            }

            // 詳細ペインと同じ判定を使う。ここだけ別に書くと、片方にだけ停止が出る状態が起きうる。
            switch state.primaryControl(for: project) {
            case .inProgress, .stop:
                Button(role: .destructive) {
                    state.stopProject(project)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!state.canStop)
                .help(state.stopBlockedReason ?? "\(project.name) のプロセスをすべて停止します")
            case .start, .noAction:
                preconditionFailure("ツールバーの開発環境に起動・停止の進捗または停止以外の操作が選ばれました。")
            }
        }
    }
}

extension AppState {
    /// 資源がまだない起動直後や、全資源の停止後も、処理完了まで対象を保つ。
    /// 管理資源の有無による停止権限の判定には使わない。
    var toolbarProject: ProjectDefinition? {
        if let operation = inlineOperation {
            guard let project = project(operation.projectID) else {
                preconditionFailure("起動・停止中の開発環境の定義がありません。")
            }
            return project
        }
        return activeProject
    }
}

extension ProjectDefinition {
    /// `openURL` を持つポートが1つもなければ「開く」を出さない。
    /// 空のメニューを置くと、開けるものがあるように見える。
    var hasOpenableURLs: Bool {
        launchUnits.contains { service in
            service.ports.contains { $0.openURL != nil }
        }
    }
}

extension ToolbarContent {
    /// macOS 26 がツールバー項目に敷くガラスの背景を外す。
    ///
    /// ガラスの背景は押すものに与えられる見た目で、読むだけの項目に付くと文字幅ぴったりの
    /// ボタンに見える。26 より前はこの背景自体がないので何もしない。可用性の分岐をここに
    /// 閉じ込め、呼び出し側で項目の定義を OS ごとに二重に書かないようにする。
    @ToolbarContentBuilder
    func sharedBackgroundHidden() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
