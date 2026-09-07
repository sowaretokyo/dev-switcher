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
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(service.name)
                    .font(Typography.heading)
                    .lineLimit(1)
                Text(service.kind.displayName)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                StatusLabel(phase: uiState.phase)
                Spacer(minLength: Spacing.s)
                // 起動・停止はプロジェクト単位でのみ行う。サービス単体の起動経路を残すと、
                // 起動順・ゲート・failurePolicy を迂回できてしまう。
                Text("起動と停止は開発環境単位")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("プロセス単体では起動・停止できません。開発環境の詳細とツールバーから操作します。")
            }

            // 値の長さは実行時に決まる。固定の横並びにすると狭い幅で切れるので折り返す。
            FlowRow(horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.m) {
                LabeledValue(label: "実測ポート", value: observedPortsText(uiState))
                LabeledValue(label: "PID", value: uiState.processID.map(String.init) ?? "—", lineLimit: 1)
                LabeledValue(
                    label: "プロセスグループ",
                    value: uiState.processGroupID.map(String.init) ?? "—",
                    lineLimit: 1
                )
                LabeledValue(label: "失敗時の扱い", value: service.failurePolicy.displayName, lineLimit: 1)
            }

            LabeledValue(label: "起動確認", value: startupObservationDescription, lineLimit: 3)
            // プロジェクト詳細から退避してきた。実行内容を確かめる場所はここ1か所にする。
            LabeledValue(label: "起動コマンド", value: service.start.displayCommandLine, lineLimit: 3)

            if let warning = uiState.warning {
                NoteText(warning, tint: .orange)
            }
            if case let .failed(reason) = uiState.phase {
                NoteText(reason, tint: .red)
            } else if let message = uiState.lastMessage, !uiState.phase.isActive {
                NoteText(message, tint: .secondary)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ buffer: LogBuffer) -> some View {
        HStack(spacing: Spacing.m) {
            Toggle("最新へ追従", isOn: $isFollowing)
                .toggleStyle(.checkbox)
                .font(Typography.support)
            Text("\(buffer.lines.count) 行")
                .font(Typography.support)
                .foregroundStyle(.secondary)
            if buffer.droppedCount > 0 {
                Text("（古い \(buffer.droppedCount) 行は破棄）")
                    .font(Typography.support)
                    .foregroundStyle(.tertiary)
            }
            if buffer.stderrCount > 0 {
                Text("stderr \(buffer.stderrCount) 行")
                    .font(Typography.support)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: Spacing.s)
            Text("ログのエラーはプロセスの状態を変えません")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
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
