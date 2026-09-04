import DevSwitcherCore
import SwiftUI

/// サイドバーは選択しか発火しない。起動・停止は詳細側の明示的なボタンで行う。
struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        List(selection: $state.selection) {
            if !activeProjects.isEmpty {
                Section("起動済み") {
                    ForEach(activeProjects) { project in
                        projectRows(project)
                    }
                }
            }
            Section("プロジェクト") {
                if inactiveProjects.isEmpty {
                    Text("登録されていません")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(inactiveProjects) { project in
                    projectRows(project)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            Button {
                state.presentProjectForm()
            } label: {
                Label("プロジェクトを追加…", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var activeProjects: [ProjectDefinition] {
        state.projects.filter { state.phase(of: $0).isActive }
    }

    private var inactiveProjects: [ProjectDefinition] {
        state.projects.filter { !state.phase(of: $0).isActive }
    }

    @ViewBuilder
    private func projectRows(_ project: ProjectDefinition) -> some View {
        ProjectRow(project: project)
            .tag(SidebarItem.project(project.id))

        if state.expandedProjectIDs.contains(project.id) {
            ForEach(project.services) { service in
                ServiceRow(project: project, service: service)
                    .tag(SidebarItem.service(projectID: project.id, serviceID: service.id))
            }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if state.expandedProjectIDs.contains(project.id) {
                    state.expandedProjectIDs.remove(project.id)
                } else {
                    state.expandedProjectIDs.insert(project.id)
                }
            } label: {
                Image(systemName: state.expandedProjectIDs.contains(project.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            ProjectChip(project: project)

            Text(project.name)
                .font(.system(size: 12.5))
                .lineLimit(1)

            Spacer(minLength: 4)

            ProjectStatusDot(phase: state.phase(of: project))
        }
        .frame(height: 27)
    }
}

private struct ServiceRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let phase = state.state(of: service.id).phase

        HStack(spacing: 6) {
            StatusDot(phase: phase)
            Text(service.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(portSummary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
        .frame(height: 25)
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
