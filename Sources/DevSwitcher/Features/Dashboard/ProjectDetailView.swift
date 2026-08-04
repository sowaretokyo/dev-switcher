import DevSwitcherCore
import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("サービス")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        if isStopped {
                            Button("既定に戻す") {
                                state.resetEnabledNow(in: project)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .disabled(state.configurationBlockedReason(for: project) != nil)
                            .help(
                                state.configurationBlockedReason(for: project)
                                    ?? "今回の起動対象の指定を消し、サービスごとの既定に従わせます。"
                            )
                        }
                    }
                    if isStopped {
                        Text("チェックを外したサービスは今回起動しません。対象外は警告や一部停止として扱いません。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(project.services) { service in
                        ServiceSummaryRow(project: project, service: service)
                    }
                }

                if !project.services.isEmpty {
                    shutdownOrderNote
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isStopped: Bool {
        !state.phase(of: project).isActive
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProjectChip(project: project)
                Text(project.name)
                    .font(.system(size: 13.5, weight: .semibold))
                ProjectStatusLabel(phase: state.phase(of: project))
                Spacer()
                openMenu
                Button("編集…") {
                    state.presentProjectForm(editing: project)
                }
                .disabled(!state.canEdit(project))
                // 無効の理由は1か所から出す。固定文にすると、稼働中でない理由で
                // 無効なときに嘘の案内を出すことになる。
                .help(state.configurationBlockedReason(for: project) ?? "プロジェクト設定を編集")
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

    /// `openUrl` を持つポートだけがメニューに載る。
    private var openMenu: some View {
        Menu("開く") {
            ForEach(project.services) { service in
                ForEach(service.ports.filter { $0.openURL != nil }) { port in
                    Button("\(service.name) — \(port.displayName)") {
                        state.open(port)
                    }
                }
            }
            Divider()
            Button("Finder で表示") {
                state.revealInFinder(project)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.phase(of: project).isActive {
                    Button("停止") {
                        state.stopProject(project)
                    }
                    // 停止に PATH は要らない。環境の取得に失敗していても止められる。
                    .disabled(!state.canStop)
                } else {
                    Button(state.activeProject == nil ? "起動" : "切り替える") {
                        state.startOrSwitch(to: project)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canStart || enabledCount == 0)
                }
                Text(startSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            // 起動できない間もボタンを黙って無効化しない。何を待っているのかを必ず出す。
            if let reason = state.startBlockedReason {
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let notice = state.switchNotice(for: project) {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enabledCount == 0 {
                Text("今回起動するサービスが選ばれていません。1つ以上チェックしてください。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var enabledCount: Int {
        project.enabledStartupOrder.count
    }

    private var startSummary: String {
        let excluded = project.excludedServices.count
        let base = "起動対象 \(enabledCount) / \(project.services.count) サービス"
        return excluded > 0 ? base + "（対象外 \(excluded)）" : base
    }

    /// 既定の終了順は起動順の逆。読み取り専用で併記する。
    private var shutdownOrderNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("終了順")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(project.shutdownOrder.map(\.name).joined(separator: " → "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(project.stopOrder == nil ? "起動順の逆（既定）" : "終了順を明示的に指定しています")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}

struct ServiceSummaryRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let uiState = state.state(of: service.id)
        let isEnabled = project.isEnabledNow(service.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 起動対象のチェックは停止中だけ変更できる。
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { state.setEnabledNow($0, for: service, in: project) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(state.configurationBlockedReason(for: project) != nil)
                .help(
                    state.configurationBlockedReason(for: project)
                        ?? "今回このサービスを起動するかどうかを切り替えます。"
                )

                Text(service.name)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(service.kind.displayName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                StatusLabel(phase: uiState.phase)
                Spacer()
                // failurePolicy は日常的に見る情報ではないので、この行にだけ小さく出す。
                if isEnabled {
                    Text(service.failurePolicy == .block ? "失敗で全体を停止" : "失敗しても続行")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
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
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        // 対象外は色を持たせない。警告色を使うと、外した日に毎回警告が出ることになる。
        .opacity(isEnabled ? 1 : 0.55)
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
        if let text = uiState.observedPortsAvailabilityText { return text }
        guard case let .observed(ports) = uiState.observedPortRecord else {
            preconditionFailure("観測状態の分岐が不足しています。")
        }
        if uiState.observedPorts.isEmpty {
            return ports.map { ":\($0)" }.joined(separator: " · ")
        }
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
