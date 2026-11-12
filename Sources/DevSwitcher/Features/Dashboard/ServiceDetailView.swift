import DevSwitcherCore
import SwiftUI

struct ServiceDetailView: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: LaunchUnit

    @State private var isFollowing = true

    var body: some View {
        let uiState = state.state(of: service.id)
        let buffer = state.logBuffer(of: service.id)

        VStack(spacing: 0) {
            // 上部の項目数は実行時に決まり、Supabase では設定ファイルや project_id が増える。
            // 縮まないまま置くと、サイドバーと同じ高さを持つ画面全体がその高さを要求し、
            // ウィンドウの上下が切れてサイドバーごと押し出される。
            // 収まるときはそのまま出し、収まらないときだけスクロールにする。常にスクロールに
            // すると、上部が短くてもログと高さを半分ずつ分け合い、ログ欄が狭くなる。
            ViewThatFits(in: .vertical) {
                header(uiState)
                ScrollView {
                    header(uiState)
                }
            }
            Divider()
            LogTextView(
                serviceID: service.id, sessionID: buffer.sessionID,
                lines: buffer.lines, isFollowing: $isFollowing
            )
            Divider()
            footer(buffer)
        }
    }

    private var serviceOperation: AppState.ServiceOperation? {
        guard let operation = state.serviceOperation,
              operation.projectID == project.id,
              operation.serviceID == service.id else { return nil }
        return operation
    }

    private func header(_ uiState: AppState.ServiceUIState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(service.name)
                    .font(Typography.heading)
                    .lineLimit(1)
                Text(service.displayTag ?? "プロセス")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                ServiceStatusLabel(state: uiState)
                Spacer(minLength: Spacing.s)
                if let serviceOperation {
                    HStack(spacing: Spacing.tight) {
                        ProgressView().controlSize(.small)
                        Text(serviceOperation.label)
                    }
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                } else if service.managedStackDefinition == nil {
                    if uiState.phase == .excluded || uiState.phase == .stopped {
                        Button {
                            state.startService(service, in: project)
                        } label: {
                            Label("起動", systemImage: "play.fill")
                        }
                        .disabled(!state.canStartService(service, in: project))
                        .help(
                            state.serviceStartBlockedReason(for: service, in: project)
                                ?? "\(service.name) を今回だけ追加で起動します"
                        )
                    } else {
                        Button {
                            state.restart(service, in: project)
                        } label: {
                            Label("再起動", systemImage: "arrow.clockwise")
                        }
                        .disabled(!state.canRestart(service, in: project))
                        .help(
                            state.restartBlockedReason(for: service, in: project)
                                ?? "\(service.name) だけを停止し、ポートの解放確認後に起動します"
                        )
                    }
                }
                Text("停止は開発環境単位")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("起動済みの開発環境では通常プロセスを追加起動・再起動できます。追加したプロセスも開発環境と一緒に停止します。")
            }

            if let serviceOperation {
                NoteText(serviceOperation.state.label, tint: .secondary)
            }

            if service.managedStackDefinition == nil, !project.isEnabledNow(service.id) {
                NoteText("一括起動の対象外です。追加起動しても、次回の一括起動には含まれません。", tint: .secondary)
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
            LabeledValue(label: "起動コマンド", value: service.commandDescription, lineLimit: 3)
            ForEach(ManagedStackTypePresentation.detailRows(for: service), id: \.label) { row in
                LabeledValue(label: row.label, value: row.value, lineLimit: row.lineLimit)
            }

            if let warning = uiState.warning {
                NoteText(warning, tint: .orange)
            }
            if let logError = uiState.logError {
                NoteText(logError, tint: .orange)
            }
            if let managedStack = uiState.managedStack {
                LabeledValue(label: "スタックの実測状態", value: managedStack.state.label)
                if let identity = managedStack.identity {
                    let presentation = ManagedStackTypePresentation(identity.type)
                    LabeledValue(label: presentation.identityFieldLabel, value: identity.value)
                    if managedStack.isExternal {
                        NoteText(presentation.externalStackNote, tint: .secondary)
                    } else if let relationship = managedStack.relationship {
                        LabeledValue(label: "管理関係", value: relationship.label)
                    }
                } else if let relationship = managedStack.relationship {
                    LabeledValue(label: "管理関係", value: relationship.label)
                }
                if let detail = managedStack.detail {
                    NoteText(detail, tint: .orange)
                }
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
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            Text("stderr はエラーとは限りません")
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
        if let definition = service.managedStackDefinition {
            return ManagedStackTypePresentation(definition.type).startupObservationDescription
        }
        do {
            return try StartupObservationPolicy.spec(for: service).description
        } catch {
            return "\(error)"
        }
    }

    private func observedPortsText(_ uiState: AppState.ServiceUIState) -> String {
        if let definition = service.managedStackDefinition, uiState.observedPortRecord == .unavailable {
            return ManagedStackTypePresentation(definition.type).portsManagedByText
        }
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
