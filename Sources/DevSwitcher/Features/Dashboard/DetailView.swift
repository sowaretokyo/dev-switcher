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
                        PlaceholderView(message: "プロジェクトを選択してください。")
                    }
                case let .service(projectID, serviceID):
                    if let project = state.project(projectID),
                       let service = project.service(id: serviceID) {
                        ServiceDetailView(project: project, service: service)
                    } else {
                        PlaceholderView(message: "サービスを選択してください。")
                    }
                case .none:
                    PlaceholderView(message: "サイドバーからプロジェクトまたはサービスを選択してください。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("プロジェクトが登録されていません")
                .font(.system(size: 13.5, weight: .semibold))
            Text("ローカルのリポジトリと起動コマンドを登録すると、ここから起動・停止できます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("プロジェクトを追加…") {
                state.presentProjectForm()
            }
            .controlSize(.large)
            .padding(.top, 4)

            Text("保存先: \(state.storeLocation)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaceholderView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
