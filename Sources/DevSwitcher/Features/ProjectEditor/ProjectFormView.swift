import AppKit
import DevSwitcherCore
import SwiftUI

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
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    projectSection($model)
                    serviceSection($model)
                    portSection($model)
                }
                .padding(16)
            }

            Divider()

            if !model.errorMessages.isEmpty {
                errorSection
                Divider()
            }

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "追加") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
    }

    private func projectSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("プロジェクト")
            LabeledContent("名前（必須）") {
                TextField("Bell", text: model.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("識別色") {
                Picker("", selection: model.color) {
                    ForEach(ProjectColor.allCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            LabeledContent("ディレクトリ（必須）") {
                HStack(spacing: 8) {
                    Text(model.wrappedValue.directory?.path ?? "未選択")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.wrappedValue.directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { chooseDirectory(for: model.wrappedValue) }
                }
            }
        }
    }

    private func serviceSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("サービス")
            LabeledContent("名前（必須）") {
                TextField("Web", text: model.serviceName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("種別") {
                Picker("", selection: model.serviceKind) {
                    ForEach(ServiceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            LabeledContent("実行ファイル（必須）") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("pnpm", text: model.executable)
                        .textFieldStyle(.roundedBorder)
                    Text("絶対パス、またはログインシェルの PATH から解決できるコマンド名。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            LabeledContent("引数") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: model.argumentsText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 60)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
                        }
                    Text("1行に1つ。シェルへは渡さず、そのまま引数として実行します。空行は無視します。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            LabeledContent("起動対象") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("既定で起動する", isOn: model.enabledByDefault)
                    Picker("起動に失敗したとき", selection: model.failurePolicy) {
                        ForEach(FailurePolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .disabled(!model.wrappedValue.enabledByDefault)
                    .frame(width: 320)
                }
            }
        }
    }

    private func portSection(_ model: Bindable<ProjectFormModel>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("ポート")
                Spacer()
                Button("追加") { model.wrappedValue.addPort() }
                    .controlSize(.small)
            }
            Text("ポートを使わないサービスは空のままで構いません。ポートがある場合は代表を1つ選びます。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            ForEach(model.ports) { $draft in
                HStack(spacing: 8) {
                    TextField("ラベル", text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField("3000", text: $draft.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    TextField("http://localhost:3000", text: $draft.openURL)
                        .textFieldStyle(.roundedBorder)
                    Toggle("代表", isOn: Binding(
                        get: { draft.isPrimary },
                        set: { _ in model.wrappedValue.makePrimary(draft.id) }
                    ))
                    .toggleStyle(.checkbox)
                    Button {
                        model.wrappedValue.removePort(draft.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var errorSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("保存できません")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.red)
                ForEach(model.errorMessages, id: \.self) { message in
                    Text("・\(message)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 100)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private func chooseDirectory(for model: ProjectFormModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "プロジェクトのローカルディレクトリを選択してください"
        panel.directoryURL = model.directory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.directory = url
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.7)
            .foregroundStyle(.secondary)
    }
}
