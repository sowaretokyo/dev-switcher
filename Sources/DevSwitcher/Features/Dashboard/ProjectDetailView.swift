import DevSwitcherCore
import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 8) {
                    Text("サービス")
                        .font(.system(size: 12.5, weight: .semibold))
                    StartBlockedNotice(project: project)
                    ForEach(project.services) { service in
                        ServiceSummaryRow(project: project, service: service)
                    }
                }

                Text("Milestone 1 ではサービスを個別に起動・停止します。起動順に沿った一括起動と、ポート解放を確認する切替は Milestone 2 で追加します。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProjectChip(project: project)
                Text(project.name)
                    .font(.system(size: 13.5, weight: .semibold))
                StatusLabel(phase: state.phase(of: project))
                Spacer()
                Button("編集…") {
                    state.presentProjectForm(editing: project)
                }
                .disabled(!state.canEdit(project))
                .help(state.canEdit(project) ? "プロジェクト設定を編集" : "稼働中のサービスを停止してから編集してください。")
            }
            Text(project.directory.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !FileManager.default.fileExists(atPath: project.directory.path) {
                Text("このディレクトリは見つかりません。起動する前に場所を確認してください。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }
        }
    }
}

struct ServiceSummaryRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let uiState = state.state(of: service.id)

        VStack(alignment: .leading, spacing: 6) {
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

            HStack(alignment: .top, spacing: 16) {
                LabeledValue(label: "設定ポート", value: configuredPorts)
                LabeledValue(label: "実測ポート", value: observedPorts(uiState))
            }

            Text(service.start.displayCommandLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

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
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var configuredPorts: String {
        guard !service.ports.isEmpty else { return "なし" }
        return service.ports
            .map { port in
                let name = port.label.flatMap { $0.isEmpty ? nil : $0 }
                return name.map { "\($0) :\(port.port)" } ?? ":\(port.port)"
            }
            .joined(separator: " · ")
    }

    private func observedPorts(_ uiState: AppState.ServiceUIState) -> String {
        guard uiState.phase.isActive else { return "—" }
        guard !uiState.observedPorts.isEmpty else { return "listen なし" }
        return uiState.observedPorts
            .map { ":\($0.port) (PID \($0.pid))" }
            .joined(separator: " · ")
    }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

struct ServiceControlButtons: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let uiState = state.state(of: service.id)
        let busy = state.isBusy(service.id)

        HStack(spacing: 8) {
            if uiState.phase.isActive {
                Button("停止") {
                    state.stop(service: service, in: project)
                }
                .disabled(busy || uiState.phase == .stopping)
            } else {
                Button("起動") {
                    state.start(service: service, in: project)
                }
                .disabled(!state.canStart(service, in: project))
                .help(state.startBlockedReason(for: project) ?? "")
            }
        }
    }
}

/// ボタンを無効にしただけで理由を出さないと、黙って何もできない画面になる。
struct StartBlockedNotice: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    var body: some View {
        if let reason = state.startBlockedReason(for: project) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
