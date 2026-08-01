import DevSwitcherCore
import SwiftUI

struct ServiceDetailView: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    @State private var isFollowing = true

    var body: some View {
        let uiState = state.state(of: service.id)
        let buffer = state.logBuffer(of: service.id)

        VStack(spacing: 0) {
            header(uiState)
            Divider()
            LogTextView(lines: buffer.lines, isFollowing: $isFollowing)
            Divider()
            footer(buffer)
        }
    }

    private func header(_ uiState: AppState.ServiceUIState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(service.name)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(service.kind.displayName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                StatusLabel(phase: uiState.phase)
                Spacer()
                ServiceControlButtons(project: project, service: service)
            }

            HStack(alignment: .top, spacing: 20) {
                LabeledValue(label: "実測ポート", value: observedPortsText(uiState))
                LabeledValue(label: "PID", value: uiState.processID.map(String.init) ?? "—")
                LabeledValue(
                    label: "プロセスグループ",
                    value: uiState.processGroupID.map(String.init) ?? "—"
                )
                LabeledValue(label: "失敗時の扱い", value: service.failurePolicy.displayName)
            }

            if !uiState.phase.isActive {
                StartBlockedNotice(project: project)
            }
            if let warning = uiState.warning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .failed(reason) = uiState.phase {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = uiState.lastMessage, !uiState.phase.isActive {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ buffer: LogBuffer) -> some View {
        HStack(spacing: 12) {
            Toggle("最新へ追従", isOn: $isFollowing)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            Text("\(buffer.lines.count) 行")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if buffer.droppedCount > 0 {
                Text("（古い \(buffer.droppedCount) 行は破棄）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if buffer.stderrCount > 0 {
                Text("stderr \(buffer.stderrCount) 行")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("ログのエラーはプロセスの状態を変えません")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func observedPortsText(_ uiState: AppState.ServiceUIState) -> String {
        guard uiState.phase.isActive else { return "—" }
        guard !uiState.observedPorts.isEmpty else { return "listen なし" }
        return uiState.observedPorts
            .map { "\($0.address):\($0.port)" }
            .joined(separator: " · ")
    }
}
