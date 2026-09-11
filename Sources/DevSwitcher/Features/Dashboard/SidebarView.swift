import DevSwitcherCore
import SwiftUI

/// サイドバーは選択しか発火しない。起動・停止は詳細側とツールバーの明示的なボタンで行う。
struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        List(selection: $state.selection) {
            if !activeProjects.isEmpty {
                Section {
                    ForEach(activeProjects) { project in
                        projectRows(project)
                    }
                } header: {
                    SectionLabel("動作中")
                }
            }
            Section {
                if inactiveProjects.isEmpty {
                    Text("登録されていません")
                        .font(Typography.support)
                        .foregroundStyle(.tertiary)
                        .rowLayout(height: Metrics.serviceRowHeight, leading: Spacing.s)
                }
                ForEach(inactiveProjects) { project in
                    projectRows(project)
                }
            } header: {
                SectionLabel("開発環境")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    state.presentProjectForm()
                } label: {
                    Label("開発環境を追加…", systemImage: "plus")
                        .font(Typography.row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
            }
            .background(.bar)
        }
    }

    private var activeProjects: [ProjectDefinition] {
        state.projects.filter { state.hasManagedResources(in: $0) }
    }

    private var inactiveProjects: [ProjectDefinition] {
        state.projects.filter { !state.hasManagedResources(in: $0) }
    }

    @ViewBuilder
    private func projectRows(_ project: ProjectDefinition) -> some View {
        ProjectRow(project: project)
            .rowLayout(height: Metrics.projectRowHeight, leading: Spacing.s)
            .tag(SidebarItem.project(project.id))

        if state.expandedProjectIDs.contains(project.id) {
            ForEach(project.services) { service in
                ServiceRow(project: project, service: service)
                    .rowLayout(height: Metrics.serviceRowHeight, leading: Spacing.indent)
                    .tag(SidebarItem.service(projectID: project.id, serviceID: service.id))
            }
        }
    }
}

private extension View {
    /// 行の高さを `DESIGN.md` 8章の値ちょうどにする。
    ///
    /// `frame` だけを指定すると List 自身の縦パディングが上乗せされ、指定した高さにならない。
    /// インデントも `padding` ではなく行のインセットで表現し、選択ハイライトの左端を揃える。
    func rowLayout(height: CGFloat, leading: CGFloat) -> some View {
        frame(height: height)
            .listRowInsets(EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: Spacing.s))
    }
}

private struct ProjectRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    private var isExpanded: Bool {
        state.expandedProjectIDs.contains(project.id)
    }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Button {
                if isExpanded {
                    state.expandedProjectIDs.remove(project.id)
                } else {
                    state.expandedProjectIDs.insert(project.id)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Metrics.disclosureIcon, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // 当たり判定を明示する。指定しないと図形の描画部分だけが反応し、
                    // 押したつもりで行の選択だけが起きる。
                    .frame(width: Spacing.m, height: Metrics.projectRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "プロセスを隠す" : "プロセスを表示")

            ProjectChip(project: project)

            Text(project.name)
                .font(Typography.row)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            ProjectStatusDot(phase: state.phase(of: project))
        }
    }
}

private struct ServiceRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let phase = state.state(of: service.id).phase
        let unreadStderrCount = state.logBuffer(of: service.id).unreadStderrCount

        HStack(spacing: Spacing.tight) {
            StatusDot(phase: phase)
            Text(service.name)
                .font(Typography.row)
                .lineLimit(1)
                .truncationMode(.tail)
            if unreadStderrCount > 0 {
                Text(unreadStderrCount > 99 ? "99+" : "\(unreadStderrCount)")
                    .font(Typography.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .help("未読の stderr が \(unreadStderrCount) 行あります。選択するとログを確認できます。")
                    .accessibilityLabel("未読エラーログ \(unreadStderrCount) 行")
            }
            Spacer(minLength: Spacing.xs)
            Text(portSummary)
                .font(Typography.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // 対象外は意図して外したものなので、警告色ではなく彩度を落として示す。
        .opacity(phase == .excluded ? 0.55 : 1)
    }

    private var portSummary: String {
        // 対象外は今回起動しないので、ポートの代わりに状態を出す。
        if state.state(of: service.id).phase == .excluded { return "対象外" }
        guard let primary = service.primaryPort else { return "ポートなし" }
        let remaining = service.ports.count - 1
        return remaining > 0 ? ":\(primary.port) +\(remaining)" : ":\(primary.port)"
    }
}
