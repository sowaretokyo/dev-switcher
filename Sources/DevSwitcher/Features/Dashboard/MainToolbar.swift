import DevSwitcherCore
import SwiftUI

/// ツールバーは稼働中のプロジェクトだけを扱う（DESIGN.md 7章・`mock.html` の `toolbar()`）。
///
/// 起動と切り替えは選択中のプロジェクト詳細が持つ。ここへ両方を置くと、
/// 「いま動いているもの」と「これから動かすもの」が同じ場所に並んで読めなくなる。
struct ToolbarIdentity: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let project = state.activeProject {
            HStack(spacing: Spacing.s) {
                ProjectChip(project: project)
                Text(project.name)
                    .font(Typography.title)
                    .lineLimit(1)
                ProjectStatusLabel(phase: state.phase(of: project))
            }
        } else {
            Text("起動中の開発環境はありません")
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 稼働中プロジェクトに対する操作。`開く` は実際に listen しているときだけ意味を持つので、
/// 停止中のプロジェクトには出さない。
struct ToolbarActions: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let project = state.activeProject {
            if project.hasOpenableURLs {
                Menu {
                    ForEach(project.services) { service in
                        ForEach(service.ports.filter { $0.openURL != nil }) { port in
                            Button("\(service.name) — \(port.displayName)") {
                                state.open(port)
                            }
                        }
                    }
                } label: {
                    Label("開く", systemImage: "arrow.up.forward.app")
                }
                .disabled(state.isOperationInFlight)
                .help("起動中のプロセスの URL を開きます")
            }

            // 詳細ペインと同じ判定を使う。ここだけ別に書くと、片方にだけ停止が出る状態が起きうる。
            switch state.primaryControl(for: project) {
            case let .inProgress(operation):
                // 進行中は押せる操作を残さない。段階そのものは詳細ペインに出す。
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(operation.kind.label)
                        .font(Typography.support)
                        .foregroundStyle(.secondary)
                }
            case .stop:
                Button(role: .destructive) {
                    state.stopProject(project)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!state.canStop)
                .help(state.stopBlockedReason ?? "\(project.name) のプロセスをすべて停止します")
            case .start, .noAction:
                // activeProject は止められる資源を持つ開発環境なので、進行中か停止にしかならない。
                preconditionFailure("稼働中の開発環境に停止以外の操作が選ばれました。")
            }
        }
    }
}

extension ProjectDefinition {
    /// `openURL` を持つポートが1つもなければ「開く」を出さない。
    /// 空のメニューを置くと、開けるものがあるように見える。
    var hasOpenableURLs: Bool {
        services.contains { service in
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
