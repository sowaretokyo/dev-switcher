import AppKit
import DevSwitcherCore
import SwiftUI

/// 追加と編集で同じ単一シートを使う。ウィザードやタブへ分割しない（`docs/SPEC.md` 15.1、15.3）。
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
            Text(isEditing ? "開発環境を編集" : "開発環境を追加")
                .font(Typography.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    projectSection($model)
                    workingDirectoriesSection($model)
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

    // MARK: - 開発環境

    private func projectSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionLabel("開発環境")
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
        }
    }

    // MARK: - 作業ディレクトリ

    private func workingDirectoriesSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionLabel("作業ディレクトリ")
                Spacer()
                Button("作業ディレクトリを追加") {
                    model.wrappedValue.addWorkingDirectory()
                }
                    .controlSize(.small)
            }
            Text("名前と場所を1回指定し、その場所から起動するプロセスをまとめます。プロセスは左端の番号順に起動します。")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
            if model.wrappedValue.hasCrossDirectoryServiceOrder {
                Text("既存の起動順を保持しているため、番号と作業ディレクトリの表示順が一致していません。ディレクトリをまたぐ順序はプロセス単位では変更できません。作業ディレクトリを並べ替えると、ディレクトリ単位の順序に揃います。")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.wrappedValue.hasExplicitStopOrder {
                // 終了順を編集する UI は Milestone 3 の対象外。黙って捨てないことだけを伝える。
                Text("この開発環境は終了順を明示的に指定しています。指定は保存時も保持し、追加したプロセスは起動順の逆の位置へ入ります。")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.wrappedValue.workingDirectories.isEmpty {
                Text("作業ディレクトリが1件もありません。1件以上追加してください。")
                    .font(Typography.support)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.workingDirectories) { $workingDirectory in
                if let index = model.wrappedValue.workingDirectories.firstIndex(where: {
                    $0.id == workingDirectory.id
                }) {
                    WorkingDirectoryCard(
                        model: model.wrappedValue,
                        workingDirectory: $workingDirectory,
                        position: index + 1
                    )
                }
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

}

/// 1つの名前付き作業ディレクトリと、そこから起動するプロセスをまとめたカード。
private struct WorkingDirectoryCard: View {
    let model: ProjectFormModel
    @Binding var workingDirectory: ProjectFormModel.WorkingDirectoryDraft
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            FormRow("名前（必須）", note: "例: Web、Native。Git リポジトリ名である必要はありません。") {
                TextField("Web", text: $workingDirectory.name)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("ディレクトリ（必須）") {
                HStack(spacing: Spacing.s) {
                    Text(workingDirectory.directory?.path ?? "未選択")
                        .font(Typography.mono)
                        .foregroundStyle(workingDirectory.directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(workingDirectory.directory?.path ?? "未選択")
                    Spacer(minLength: Spacing.s)
                    Button("選択…") {
                        guard let url = chooseDirectory(
                            message: "このグループのプロセスを起動するディレクトリを選択してください",
                            startingAt: workingDirectory.directory
                        ) else { return }
                        workingDirectory.directory = url
                        if workingDirectory.name.trimmed.isEmpty {
                            workingDirectory.name = url.lastPathComponent
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                SectionLabel("プロセス")
                Spacer()
                Button("プロセスを追加") {
                    model.addService(to: workingDirectory.id)
                }
                .controlSize(.small)
            }

            if workingDirectory.services.isEmpty && workingDirectory.stacks.isEmpty {
                Text("プロセスまたはスタックを1件以上追加してください。")
                    .font(Typography.support)
                    .foregroundStyle(.orange)
            }

            HStack {
                SectionLabel("管理対象スタック（プロセスより先に起動）")
                Spacer()
                Menu("スタックを追加") {
                    ForEach(ManagedStackType.allCases, id: \.self) { type in
                        Button(type.displayName) { model.addStack(type, to: workingDirectory.id) }
                    }
                }
            }
            ForEach($workingDirectory.stacks) { $stack in
                StackCard(model: model, stack: $stack)
            }
            ForEach($workingDirectory.services) { $service in
                if let position = model.positionIfPresent(of: service.id) {
                    ServiceCard(model: model, service: $service, position: position)
                }
            }
        }
        .padding(Spacing.m)
        .background(
            .quaternary.opacity(0.22),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text("\(position)")
                .font(Typography.monoSmall.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(workingDirectory.name.trimmed.isEmpty ? "新しい作業ディレクトリ" : workingDirectory.name.trimmed)
                .font(Typography.heading)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.s)
            Button {
                model.moveWorkingDirectory(workingDirectory.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canMoveWorkingDirectory(workingDirectory.id, by: -1))
            .help("作業ディレクトリを前へ")
            Button {
                model.moveWorkingDirectory(workingDirectory.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canMoveWorkingDirectory(workingDirectory.id, by: 1))
            .help("作業ディレクトリを後ろへ")
            Button(role: .destructive) {
                model.removeWorkingDirectory(workingDirectory.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この作業ディレクトリとプロセス設定を削除")
        }
    }
}

/// 1プロセス分の入力カード。並べ替えはカード内の起動順をそのまま動かす。
private struct ServiceCard: View {
    let model: ProjectFormModel
    @Binding var service: ProjectFormModel.ServiceDraft
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            FormRow("名前（必須）") {
                TextField("Web", text: $service.name)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("タグ（任意）", note: "表示用の32文字以内のタグです。起動・停止の挙動は変わりません。") {
                TextField("web / worker", text: $service.tag).textFieldStyle(.roundedBorder)
            }
            FormRow(
                "実行ファイル（必須）",
                note: "絶対パス、またはログインシェルの PATH から解決できるコマンド名。"
            ) {
                TextField("pnpm", text: $service.executable)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow(
                service.argumentsFormat == .json ? "引数（JSON配列）" : "引数",
                note: service.argumentsFormat == .json
                    ? "引数内の改行や前後の空白を保持するため、JSONの文字列配列で編集します。改行は \\n と記述します。引数なしは [] です。"
                    : "1行に1つ。シェルへ渡さず、そのまま引数として実行します。空行は無視します。"
            ) {
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
            FormRow("停止コマンド（任意）", note: "指定すると SIGTERM の代わりにこのコマンドを実行します。") {
                Toggle("停止コマンドを使う", isOn: $service.hasStopCommand)
                if service.hasStopCommand {
                    TextField("実行ファイル", text: $service.stopExecutable).textFieldStyle(.roundedBorder)
                    TextField("引数（JSON配列）", text: $service.stopArgumentsJSON).textFieldStyle(.roundedBorder)
                    HStack {
                        Text(service.stopDirectory?.path ?? "起動コマンドと同じ作業ディレクトリ").font(Typography.caption)
                        Button("場所を選択…") {
                            guard let url = chooseDirectory(
                                message: "停止コマンドの作業ディレクトリ",
                                startingAt: service.stopDirectory
                            ) else { return }
                            service.stopDirectory = url
                        }
                        Button("起動と同じ") { service.stopDirectory = nil }
                    }
                }
            }
            ForEach(service.commandWarnings, id: \.self) { warning in
                Text(warning).font(Typography.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            FormRow("起動対象") {
                Toggle("既定で起動する", isOn: $service.enabledByDefault)
                Picker("起動に失敗したとき", selection: $service.failurePolicy) {
                    ForEach(FailurePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
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
            Text(service.name.trimmed.isEmpty ? "新しいプロセス" : service.name.trimmed)
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
            .help("このプロセスを削除")
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

private struct StackCard: View {
    let model: ProjectFormModel
    @Binding var stack: ProjectFormModel.StackDraft
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("スタック \(model.stackPosition(stack.id) ?? 0)・\(stack.type.displayName)").font(Typography.heading)
                Spacer()
                Button { model.moveStack(stack.id, by: -1) } label: { Image(systemName: "chevron.up") }
                Button { model.moveStack(stack.id, by: 1) } label: { Image(systemName: "chevron.down") }
                Button(role: .destructive) { model.removeStack(stack.id) } label: { Image(systemName: "trash") }
            }.buttonStyle(.borderless)
            FormRow("名前（必須）") { TextField("名前", text: $stack.name).textFieldStyle(.roundedBorder) }
            if stack.type == .supabase {
                FormRow("実行ファイル") { TextField("supabase", text: $stack.executable).textFieldStyle(.roundedBorder) }
                FormRow("引数（JSON配列）") { TextField("[\"start\"]", text: $stack.argumentsJSON).textFieldStyle(.roundedBorder) }
            } else {
                FormRow("プロジェクト名（任意）", note: "省略時は name:、最初の Compose ファイルのディレクトリ名の順で決定します。") {
                    TextField("my-project", text: $stack.projectName).textFieldStyle(.roundedBorder)
                }
                FormRow("ファイル（JSON配列）", note: "相対パスの配列。空欄なら作業ディレクトリ直下の既定ファイルを使います。") {
                    TextField("[\"compose.yaml\"]", text: $stack.filesJSON).textFieldStyle(.roundedBorder)
                }
                FormRow("profiles（JSON配列）", note: "起動・観測に使います。空欄なら省略し、停止時は全 profile を対象にします。") {
                    TextField("[\"dev\"]", text: $stack.profilesJSON).textFieldStyle(.roundedBorder)
                }
                FormRow("起動追加引数（JSON配列）", note: "up -d の後に渡します。追加なしは []。") {
                    TextField("[]", text: $stack.upArgumentsJSON).textFieldStyle(.roundedBorder)
                }
                Text("停止は同じプロジェクト名の全 profile が対象です。設定外の profile も停止します。コンテナやボリュームは削除しません。正常終了する one-shot サービスが混在すると一部異常として扱います。")
                    .font(Typography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FormRow("起動対象") {
                Toggle("既定で起動する", isOn: $stack.enabledByDefault)
                Picker("起動に失敗したとき", selection: $stack.failurePolicy) {
                    ForEach(FailurePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            FormRow("ポート（任意）") {
                Button("ポートを追加") { stack.ports.append(.init(isPrimary: stack.ports.isEmpty)) }
                ForEach($stack.ports) { $port in
                    HStack {
                        TextField("ラベル", text: $port.label).frame(width: Metrics.portLabelFieldWidth)
                        TextField("5432", text: $port.port).frame(width: Metrics.portNumberFieldWidth)
                        TextField("http://localhost:5432", text: $port.openURL)
                        Toggle("代表", isOn: Binding(get: { port.isPrimary }, set: { _ in
                            for index in stack.ports.indices { stack.ports[index].isPrimary = stack.ports[index].id == port.id }
                        })).toggleStyle(.checkbox)
                        Button { stack.ports.removeAll { $0.id == port.id } } label: { Image(systemName: "minus.circle") }
                    }.textFieldStyle(.roundedBorder)
                }
            }
        }.padding(Spacing.m).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card))
    }
}
