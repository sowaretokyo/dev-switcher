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
            Text("起動中のプロジェクトはありません")
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
                .help("起動中のサービスの URL を開きます")
            }

            if let operation = state.inlineOperation, operation.projectID == project.id {
                // 進行中は押せる操作を残さない。段階そのものは詳細ペインに出す。
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(operation.kind.label)
                        .font(Typography.support)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(role: .destructive) {
                    state.stopProject(project)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!state.canStop)
                .help(state.stopBlockedReason ?? "\(project.name) のサービスをすべて停止します")
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
