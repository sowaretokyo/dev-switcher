import AppKit
import DevSwitcherCore
import SwiftUI

/// 追加と編集で同じ単一シートを使う。ウィザードやタブへ分割しない（DESIGN.md 決定 i）。
///
/// 入力行はすべて `FormRow` に統一する。`LabeledContent` はコンテナごとにラベル列幅を
/// 計算するため、シート直下の欄とサービスカードの中の欄で右端が揃わない。
struct ProjectFormView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    private let isEditing: Bool
    @State private var model: ProjectFormModel

    init(project: ProjectDefinition? = nil) {
        isEditing = project != nil
        _model = State(initialValue: ProjectFormModel(project: project))
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Text(isEditing ? "プロジェクトを編集" : "プロジェクトを追加")
                .font(Typography.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    projectSection($model)
                    servicesSection($model)
                }
                .padding(Spacing.l)
            }

            Divider()

            if !model.errorMessages.isEmpty {
                errorSection
                Divider()
            }

            HStack(spacing: Spacing.s) {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "追加") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.l)
        }
        .frame(width: Metrics.editorSheetWidth, height: Metrics.editorSheetHeight)
    }

    // MARK: - プロジェクト

    private func projectSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionLabel("プロジェクト")
            FormRow("名前（必須）") {
                TextField("Bell", text: model.name)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("識別色") {
                Picker("", selection: model.color) {
                    ForEach(ProjectColor.allCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            FormRow("ディレクトリ（必須）") {
                HStack(spacing: Spacing.s) {
                    Text(model.wrappedValue.directory?.path ?? "未選択")
                        .font(Typography.mono)
                        .foregroundStyle(model.wrappedValue.directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(model.wrappedValue.directory?.path ?? "未選択")
                    Spacer(minLength: Spacing.s)
                    Button("選択…") { chooseProjectDirectory(for: model.wrappedValue) }
                }
            }
        }
    }

    // MARK: - サービス

    private func servicesSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionLabel("サービス")
                Spacer()
                Button("サービスを追加") { model.wrappedValue.addService() }
                    .controlSize(.small)
            }
            Text("上から順に起動します。終了順は既定でこの逆です。")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
            if model.wrappedValue.hasExplicitStopOrder {
                // 終了順を編集する UI は Milestone 3 の対象外。黙って捨てないことだけを伝える。
                Text("このプロジェクトは終了順を明示的に指定しています。指定は保存時も保持し、追加したサービスは起動順の逆の位置へ入ります。")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.wrappedValue.services.isEmpty {
                Text("サービスが1つもありません。「サービスを追加」から1つ以上登録してください。")
                    .font(Typography.support)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.services) { $service in
                ServiceCard(model: model.wrappedValue, service: $service)
            }
        }
    }

    private var errorSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("保存できません")
                    .font(Typography.support.weight(.semibold))
                    .foregroundStyle(.red)
                ForEach(model.errorMessages, id: \.self) { message in
                    Text("・\(message)")
                        .font(Typography.support)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Metrics.formErrorMaxHeight)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Color.red.opacity(0.06))
    }

    private func save() {
        do {
            let project = try model.build()
            if isEditing {
                try state.updateProject(project)
            } else {
                try state.addProject(project)
            }
            dismiss()
        } catch let failure as ValidationFailure {
            model.errorMessages = failure.errors.map(\.description)
        } catch {
            model.errorMessages = ["\(error)"]
        }
    }

    private func chooseProjectDirectory(for model: ProjectFormModel) {
        guard let url = chooseDirectory(
            message: "プロジェクトのローカルディレクトリを選択してください",
            startingAt: model.directory
        ) else { return }
        model.directory = url
    }
}

/// 1サービス分の入力カード。並べ替えは配列順＝起動順をそのまま動かす。
private struct ServiceCard: View {
    let model: ProjectFormModel
    @Binding var service: ProjectFormModel.ServiceDraft

    /// 起動順の位置。配列から引き直すので、並べ替えても番号がずれない。
    private var position: Int {
        (model.services.firstIndex { $0.id == service.id } ?? 0) + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            FormRow("名前（必須）") {
                TextField("Web", text: $service.name)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("種別") {
                Picker("", selection: $service.kind) {
                    ForEach(ServiceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            FormRow(
                "実行ファイル（必須）",
                note: "絶対パス、またはログインシェルの PATH から解決できるコマンド名。"
            ) {
                TextField("pnpm", text: $service.executable)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("引数", note: "1行に1つ。シェルへ渡さず、そのまま引数として実行します。空行は無視します。") {
                TextEditor(text: $service.argumentsText)
                    .font(Typography.mono)
                    .scrollContentBackground(.hidden)
                    .frame(height: Metrics.argumentsEditorHeight)
                    .padding(.horizontal, Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control).strokeBorder(.separator)
                    }
            }
            workingDirectoryRow
            FormRow("起動対象") {
                Toggle("既定で起動する", isOn: $service.enabledByDefault)
                Picker("起動に失敗したとき", selection: $service.failurePolicy) {
                    ForEach(FailurePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .disabled(!service.enabledByDefault)
                .fixedSize()
            }
            portSection
        }
        .padding(Spacing.m)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text("\(position)")
                .font(Typography.monoSmall.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(service.name.trimmed.isEmpty ? "新しいサービス" : service.name.trimmed)
                .font(Typography.heading)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.s)
            Button {
                model.moveService(service.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canMoveService(service.id, by: -1))
            .help("起動順を1つ前へ")
            Button {
                model.moveService(service.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canMoveService(service.id, by: 1))
            .help("起動順を1つ後ろへ")
            Button(role: .destructive) {
                model.removeService(service.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("このサービスを削除")
        }
    }

    /// 作業ディレクトリはサービスごとに指定できる。
    /// 未指定は「プロジェクトディレクトリに従う」という指定で、保存時に実際の値を埋める。
    private var workingDirectoryRow: some View {
        FormRow(
            "作業ディレクトリ",
            note: "モノレポのサブパッケージなど、プロジェクト直下と違う場所から起動する場合に指定します。"
        ) {
            HStack(spacing: Spacing.s) {
                Text(service.workingDirectory?.path ?? "プロジェクトディレクトリと同じ")
                    .font(Typography.mono)
                    .foregroundStyle(service.workingDirectory == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(service.workingDirectory?.path ?? "プロジェクトディレクトリと同じ")
                Spacer(minLength: Spacing.s)
                if service.workingDirectory != nil {
                    Button("プロジェクトと同じ") { service.workingDirectory = nil }
                        .controlSize(.small)
                }
                Button("選択…") {
                    guard let url = chooseDirectory(
                        message: "このサービスを起動する作業ディレクトリを選択してください",
                        startingAt: service.workingDirectory ?? model.directory
                    ) else { return }
                    service.workingDirectory = url
                }
                .controlSize(.small)
            }
        }
    }

    /// ポートの扱いは説明が長い。行に出すのは要点だけにし、全文はツールチップへ逃がす。
    private var portSection: some View {
        FormRow(
            "ポート（任意）",
            note: "表示と「開く」の URL にだけ使います。起動の可否や成功の判定には使いません。"
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Button("ポートを追加") { model.addPort(to: service.id) }
                        .controlSize(.small)
                    Spacer(minLength: Spacing.s)
                }
                .help(portHelp)

                ForEach($service.ports) { $port in
                    HStack(spacing: Spacing.s) {
                        TextField("ラベル", text: $port.label)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Metrics.portLabelFieldWidth)
                        TextField("3000", text: $port.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Metrics.portNumberFieldWidth)
                        TextField("http://localhost:3000", text: $port.openURL)
                            .textFieldStyle(.roundedBorder)
                        Toggle("代表", isOn: Binding(
                            get: { port.isPrimary },
                            set: { _ in model.makePrimary(port.id, in: service.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("代表ポートはサイドバーに出す1つです。")
                        Button {
                            model.removePort(port.id, from: service.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("このポートを削除")
                    }
                }
            }
        }
    }

    private var portHelp: String {
        """
        ポートは全サービスで任意です。空のままでも登録・起動できます。
        入力する場合は代表を1つ選びます。別のサービスと同じ番号でも保存できます。
        起動コマンドへ `--port` などは追加しません。ポートの取得は OS に任せ、\
        実際に listen した番号を実測ポートとして表示します。
        """
    }
}

/// 利用者が選んだ実在のディレクトリだけを受け取る。手入力のパスを組み立てない。
@MainActor
private func chooseDirectory(message: String, startingAt: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    panel.message = message
    panel.directoryURL = startingAt

    guard panel.runModal() == .OK else { return nil }
    return panel.url
}
