import DevSwitcherCore
import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                controls
                servicesSection
                if !project.services.isEmpty {
                    shutdownOrderNote
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isStopped: Bool {
        !state.phase(of: project).isActive
    }

    // MARK: - ヘッダー

    /// 稼働中プロジェクトの操作はツールバーが持つ。ここは「いま選んでいるのはどれか」だけを示す。
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
                ProjectChip(project: project)
                Text(project.name)
                    .font(Typography.title)
                    .lineLimit(1)
                ProjectStatusLabel(phase: state.phase(of: project))
                Spacer(minLength: Spacing.s)
                moreMenu
            }
            Text(project.directory.path)
                .font(Typography.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.head)
                .help(project.directory.path)
            if !FileManager.default.fileExists(atPath: project.directory.path) {
                Text("このディレクトリは見つかりません。起動する前に場所を確認してください。")
                    .font(Typography.support)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 編集と登録解除の導線（DESIGN.md 決定 i）。複製はPost-MVPなので出さない。
    private var moreMenu: some View {
        Menu {
            Button("編集…") {
                state.presentProjectForm(editing: project)
            }
            .disabled(!state.canEdit(project))
            Button("Finder で表示") {
                state.revealInFinder(project)
            }
            Divider()
            Button("登録を解除…") {
                state.presentUnregisterConfirmation(for: project)
            }
            .disabled(!state.canUnregister(project))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // 無効の理由は1か所から出す。固定文にすると、稼働中でない理由で
        // 無効なときに嘘の案内を出すことになる。
        .help(
            state.configurationBlockedReason(for: project)
                ?? "プロジェクトの編集・Finder 表示・登録解除"
        )
    }

    // MARK: - 起動

    /// このプロジェクトを対象にした、シートを出さない進行中の操作。
    private var inlineOperation: AppState.InlineOperation? {
        guard let operation = state.inlineOperation, operation.projectID == project.id else {
            return nil
        }
        return operation
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
                if let inlineOperation {
                    // 進捗はボタンの中で示す。画面を遮らないので、シートが一瞬だけ
                    // 出て消えることがない。二重操作は AppState の API 境界が止める。
                    Button {} label: {
                        HStack(spacing: Spacing.tight) {
                            ProgressView().controlSize(.small)
                            Text(inlineOperation.kind.label)
                        }
                    }
                    .disabled(true)
                } else if isStopped {
                    Button(state.activeProject == nil ? "起動" : "切り替える") {
                        state.startOrSwitch(to: project)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canStart || enabledCount == 0)
                }
                Text(startSummary)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
            }
            // いまどの段階かを出す。ボタンの「起動中」だけでは、
            // どのサービスで止まっているのか分からない。
            // 自分の操作中に「ほかの処理を実行中」と出さないよう、理由表示より優先する。
            if let inlineOperation {
                NoteText(inlineOperation.state.label, tint: .secondary)
            } else if isStopped, let reason = state.startBlockedReason {
                // 起動できない間もボタンを黙って無効化しない。何を待っているのかを必ず出す。
                NoteText(reason, tint: .orange)
            } else if let notice = state.switchNotice(for: project) {
                NoteText(notice, tint: .secondary)
            }
            if isStopped, enabledCount == 0 {
                NoteText("今回起動するサービスが選ばれていません。1つ以上チェックしてください。", tint: .orange)
            }
            if !isStopped {
                NoteText("停止はツールバーの「停止」から行います。", tint: .secondary)
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

    // MARK: - サービス

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionLabel("サービス")
                Spacer()
                if isStopped {
                    Button("既定に戻す") {
                        state.resetEnabledNow(in: project)
                    }
                    .buttonStyle(.link)
                    .font(Typography.support)
                    .disabled(state.configurationBlockedReason(for: project) != nil)
                    .help(
                        state.configurationBlockedReason(for: project)
                            ?? "今回の起動対象の指定を消し、サービスごとの既定に従わせます。"
                    )
                }
            }
            // 起動コマンドと実測ポートはサービス詳細が持つ。ここへ並べると1画面で
            // 読み切れず、「今回どれを起動するか」という本来の判断が埋もれる。
            Text(
                isStopped
                    ? "チェックを外したサービスは今回起動しません。対象外は警告や一部停止として扱いません。コマンドと実測ポートはサービスを選ぶと表示します。"
                    : "コマンドと実測ポートはサービスを選ぶと表示します。"
            )
            .font(Typography.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(project.services) { service in
                ServiceSummaryRow(project: project, service: service)
            }
        }
    }

    /// 既定の終了順は起動順の逆。読み取り専用で併記する。
    private var shutdownOrderNote: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            SectionLabel("終了順")
            Text(project.shutdownOrder.map(\.name).joined(separator: " → "))
                .font(Typography.mono)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(project.stopOrder == nil ? "起動順の逆（既定）" : "終了順を明示的に指定しています")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 起動対象のチェックリスト1行。
///
/// ここが答えるのは「今回このサービスを起動するか」だけ。実行時の詳細は
/// サービスを選んだときの画面に置く。
struct ServiceSummaryRow: View {
    @Environment(AppState.self) private var state
    let project: ProjectDefinition
    let service: ServiceDefinition

    var body: some View {
        let uiState = state.state(of: service.id)
        let isEnabled = project.isEnabledNow(service.id)

        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
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
                .accessibilityLabel("\(service.name) を今回起動する")
                .help(
                    state.configurationBlockedReason(for: project)
                        ?? "今回このサービスを起動するかどうかを切り替えます。"
                )

                Text(service.name)
                    .font(Typography.heading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Spacing.s)

                StatusLabel(phase: uiState.phase)
            }

            // 補助情報は固定の横並びにしない。狭い詳細ペインで黙って切れる。
            FlowRow(horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                Text(service.kind.displayName)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Text(configuredPorts)
                    .font(Typography.monoSmall)
                    .foregroundStyle(.secondary)
                    .help("設定ポート")
                // failurePolicy は日常的に見る情報ではないので、この行にだけ小さく出す。
                if isEnabled {
                    Text(service.failurePolicy == .block ? "失敗で全体を停止" : "失敗しても続行")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, Metrics.checkboxIndent)

            if let warning = uiState.warning {
                NoteText(warning, tint: .orange, indent: Metrics.checkboxIndent)
            }
            if case let .failed(reason) = uiState.phase {
                NoteText(reason, tint: .red, indent: Metrics.checkboxIndent)
            }
        }
        .padding(Spacing.m)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // 対象外は色を持たせない。警告色を使うと、外した日に毎回警告が出ることになる。
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var configuredPorts: String {
        guard !service.ports.isEmpty else { return "ポートなし" }
        return service.ports
            .map { port in
                let name = port.label.flatMap { $0.isEmpty ? nil : $0 }
                return name.map { "\($0) :\(port.port)" } ?? ":\(port.port)"
            }
            .joined(separator: " · ")
    }
}
