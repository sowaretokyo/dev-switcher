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
                // 起動・停止はプロジェクト単位でのみ行う。サービス単体の起動経路を残すと、
                // 起動順・ゲート・failurePolicy を迂回できてしまう。
                Text("起動と停止はプロジェクト単位で行います")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
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

            LabeledValue(label: "起動確認", value: startupObservationDescription)

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

    /// 何を見て起動成功と判断しているかを表示する。
    /// HTTP は投げないので、応答するかどうかまでは保証しないことが分かる文言にする。
    private var startupObservationDescription: String {
        do {
            return try StartupObservationPolicy.spec(for: service).description
        } catch {
            return "\(error)"
        }
    }

    private func observedPortsText(_ uiState: AppState.ServiceUIState) -> String {
        if let text = uiState.observedPortsAvailabilityText { return text }
        guard case let .observed(ports) = uiState.observedPortRecord else {
            preconditionFailure("観測状態の分岐が不足しています。")
        }
        if uiState.observedPorts.isEmpty {
            return ports.map { ":\($0)" }.joined(separator: " · ")
        }
        return uiState.observedPorts
            .map { "\($0.address):\($0.port)" }
            .joined(separator: " · ")
    }
}
