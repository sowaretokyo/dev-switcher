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
            LogTextView(serviceID: service.id, lines: buffer.lines, isFollowing: $isFollowing)
            Divider()
            footer(buffer)
        }
        .onAppear {
            state.markLogAsRead(serviceID: service.id)
        }
        .onChange(of: service.id) { _, serviceID in
            state.markLogAsRead(serviceID: serviceID)
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
                Text(service.kind.displayName)
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
                } else if service.kind != .supabase {
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

            if service.kind != .supabase, !project.isEnabledNow(service.id) {
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
            LabeledValue(label: "起動コマンド", value: service.start.displayCommandLine, lineLimit: 3)
            if let configuration = service.supabaseConfiguration {
                LabeledValue(
                    label: "状態確認",
                    value: configuration.statusCommand.displayCommandLine,
                    lineLimit: 3
                )
                LabeledValue(
                    label: "設定ファイル",
                    value: configuration.configFileURL.path,
                    lineLimit: 2
                )
            }

            if let warning = uiState.warning {
                NoteText(warning, tint: .orange)
            }
            if let supabase = uiState.supabase {
                LabeledValue(label: "スタックの実測状態", value: supabase.state.label)
                if let projectID = supabase.projectID {
                    LabeledValue(label: "project_id", value: projectID.rawValue)
                }
                if supabase.isExternal {
                    NoteText("外部で起動されたSupabaseです。開発環境の起動時に引き継ぎを確認します。", tint: .secondary)
                } else if let relationship = supabase.relationship {
                    LabeledValue(label: "管理関係", value: relationship.label)
                }
                if let detail = supabase.detail {
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
        if service.kind == .supabase {
            return "Dockerの実測でDBコンテナがhealthyになり、対象workdirの `supabase status` も成功すること"
        }
        do {
            return try StartupObservationPolicy.spec(for: service).description
        } catch {
            return "\(error)"
        }
    }

    private func observedPortsText(_ uiState: AppState.ServiceUIState) -> String {
        if service.kind == .supabase, uiState.observedPortRecord == .unavailable {
            return "Supabase CLI で管理"
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
