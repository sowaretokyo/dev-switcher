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
        !state.hasManagedResources(in: project)
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
            Text("作業ディレクトリ \(project.workingDirectories.count) 件・プロセス \(project.services.count) 件")
                .font(Typography.support)
                .foregroundStyle(.secondary)
        }
    }

    /// 編集と登録解除の導線（`docs/SPEC.md` 15.1、15.3）。複製はPost-MVPなので出さない。
    private var moreMenu: some View {
        Menu {
            Button("編集…") {
                state.presentProjectForm(editing: project)
            }
            .disabled(!state.canEdit(project))
            Menu("Finder で表示") {
                ForEach(project.workingDirectories) { workingDirectory in
                    Button(workingDirectory.name) {
                        state.revealInFinder(workingDirectory)
                    }
                }
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
                ?? "開発環境の編集・Finder 表示・登録解除"
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

    private var primaryControl: ProjectPrimaryControl {
        state.primaryControl(for: project)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
                switch primaryControl {
                case let .inProgress(operation):
                    // 進捗はボタンの中で示す。画面を遮らないので、シートが一瞬だけ
                    // 出て消えることがない。二重操作は AppState の API 境界が止める。
                    Button {} label: {
                        HStack(spacing: Spacing.tight) {
                            ProgressView().controlSize(.small)
                            Text(operation.kind.label)
                        }
                    }
                    .disabled(true)
                case .stop:
                    // 起動と同じ場所に置く。ツールバーだけにすると、ここを見ている人が
                    // 停止の場所を探すことになる。止める操作なので既定ボタンにはしない。
                    Button("停止", role: .destructive) {
                        state.stopProject(project)
                    }
                    .disabled(!state.canStop)
                case .start:
                    Button(state.activeProject == nil ? "起動" : "切り替える") {
                        state.startOrSwitch(to: project)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canStart || enabledCount == 0)
                case .noAction:
                    EmptyView()
                }
                Text(startSummary)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
            }
            // いまどの段階かを出す。ボタンの「起動中」だけでは、
            // どのサービスで止まっているのか分からない。
            // 自分の操作中に「ほかの処理を実行中」と出さないよう、理由表示より優先する。
            if case let .inProgress(operation) = primaryControl {
                NoteText(operation.state.label, tint: .secondary)
            } else if let reason = blockedReason {
                // 押せない間もボタンを黙って無効化しない。何を待っているのかを必ず出す。
                NoteText(reason, tint: .orange)
            } else if let notice = state.switchNotice(for: project) {
                NoteText(notice, tint: .secondary)
            }
            if primaryControl == .start, enabledCount == 0 {
                NoteText("今回起動するプロセスが選ばれていません。1つ以上チェックしてください。", tint: .orange)
            }
        }
    }

    /// 出しているボタンが押せない理由。ボタンと別の判定で理由を選ぶと、
    /// 停止ボタンの下に起動できない理由が出るような食い違いが起きる。
    private var blockedReason: String? {
        switch primaryControl {
        case .stop: state.stopBlockedReason
        case .start: state.startBlockedReason
        case .inProgress, .noAction: nil
        }
    }

    private var enabledCount: Int {
        project.enabledStartupOrder.count
    }

    private var startSummary: String {
        let excluded = project.excludedServices.count
        let base = "起動対象 \(enabledCount) / \(project.services.count) プロセス"
        return excluded > 0 ? base + "（対象外 \(excluded)）" : base
    }

    // MARK: - サービス

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionLabel("作業ディレクトリとプロセス")
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
                            ?? "今回の起動対象の指定を消し、プロセスごとの既定に従わせます。"
                    )
                }
            }
            // 起動コマンドと実測ポートはサービス詳細が持つ。ここへ並べると1画面で
            // 読み切れず、「今回どれを起動するか」という本来の判断が埋もれる。
            Text(
                isStopped
                    ? "チェックを外したプロセスは今回起動しません。対象外は警告や一部停止として扱いません。"
                    : "コマンドと実測ポートはサイドバーからプロセスを選ぶと表示します。"
            )
            .font(Typography.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            Text("左端の番号は起動順です。")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)

            ForEach(project.workingDirectories) { workingDirectory in
                WorkingDirectorySummary(
                    project: project,
                    workingDirectory: workingDirectory
                )
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

private struct WorkingDirectorySummary: View {
    let project: ProjectDefinition
    let workingDirectory: WorkingDirectoryDefinition

    private var services: [ServiceDefinition] {
        workingDirectory.serviceIDs.map { serviceID in
            guard let service = project.service(id: serviceID) else {
                preconditionFailure("作業ディレクトリに存在しないプロセス ID が含まれています。")
            }
            return service
        }
    }

    private var directoryIsAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: workingDirectory.directory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(workingDirectory.name)
                    .font(Typography.heading)
                Spacer(minLength: Spacing.s)
                Text("\(services.count) プロセス")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(workingDirectory.directory.path)
                .font(Typography.monoSmall)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.head)
                .help(workingDirectory.directory.path)

            if !directoryIsAvailable {
                NoteText("このディレクトリを利用できません。", tint: .red)
            }

            ForEach(services) { service in
                ServiceSummaryRow(project: project, service: service)
                    .padding(.leading, Spacing.m)
            }
        }
        .padding(Spacing.m)
        .background(
            .quaternary.opacity(0.2),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
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

    private var startupPosition: Int {
        guard let index = project.services.firstIndex(where: { $0.id == service.id }) else {
            preconditionFailure("存在しないプロセスの起動順は表示できません。")
        }
        return index + 1
    }

    var body: some View {
        let uiState = state.state(of: service.id)
        let isEnabled = project.isEnabledNow(service.id)

        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.s) {
                Text("\(startupPosition)")
                    .font(Typography.monoSmall.weight(.bold))
                    .foregroundStyle(.tertiary)
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

                ServiceStatusLabel(state: uiState)
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
            if let detail = uiState.managedStack?.detail {
                NoteText(detail, tint: .orange, indent: Metrics.checkboxIndent)
            }
            if case let .failed(reason) = uiState.phase {
                NoteText(reason, tint: .red, indent: Metrics.checkboxIndent)
            }
        }
        .padding(Spacing.m)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // 対象外は色を持たせない。警告色を使うと、外した日に毎回警告が出ることになる。
        .opacity(uiState.phase == .excluded ? 0.55 : 1)
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
