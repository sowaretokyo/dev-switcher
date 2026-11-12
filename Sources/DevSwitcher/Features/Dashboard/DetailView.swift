import DevSwitcherCore
import SwiftUI

struct DetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.projects.isEmpty {
                EmptyStateView()
            } else {
                switch state.selection {
                case let .project(id):
                    if let project = state.project(id) {
                        ProjectDetailView(project: project)
                    } else {
                        PlaceholderView(message: L10n.text("開発環境を選択してください。"))
                    }
                case let .service(projectID, serviceID):
                    if let project = state.project(projectID),
                       let service = project.entry(id: serviceID) {
                        ServiceDetailView(project: project, service: service)
                    } else {
                        PlaceholderView(message: L10n.text("プロセスを選択してください。"))
                    }
                case .none:
                    PlaceholderView(message: L10n.text("サイドバーから開発環境またはプロセスを選択してください。"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: Metrics.emptyStateIcon, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.text("開発環境が登録されていません"))
                .font(Typography.title)
            Text(L10n.text("名前付きディレクトリと起動コマンドを登録すると、ここから一括で起動・停止できます。"))
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.emptyStateTextWidth)
            Button(L10n.text("開発環境を追加…")) {
                state.presentProjectForm()
            }
            .controlSize(.large)
            .padding(.top, Spacing.xs)

            Text(L10n.text("保存先: \(state.storeLocation)"))
                .font(Typography.monoSmall)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: Metrics.emptyStateTextWidth)
                .padding(.top, Spacing.s)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaceholderView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(Typography.support)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
