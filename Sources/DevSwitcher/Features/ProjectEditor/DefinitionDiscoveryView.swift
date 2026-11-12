import DevSwitcherCore
import SwiftUI

/// 候補を出典ごとの行で示す。操作説明は常設せず、補足は詳細から確認する。
struct DefinitionDiscoveryView: View {
    let directory: URL?
    let add: (DefinitionDiscovery.Result, Set<String>, ScriptPackageManager?, Bool) throws -> Void
    @State private var preview: DefinitionDiscovery.Result?
    @State private var selectedScripts: Set<String> = []
    @State private var manager: ScriptPackageManager?
    @State private var includeCompose = false
    @State private var errorMessage: String?

    init(directory: URL?, preview: DefinitionDiscovery.Result? = nil,
         add: @escaping (DefinitionDiscovery.Result, Set<String>, ScriptPackageManager?, Bool) throws -> Void) {
        self.directory = directory
        self.add = add
        _preview = State(initialValue: preview)
        _manager = State(initialValue: preview?.suggestedManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let preview {
                candidates(preview)
            } else {
                Button("定義から追加…", systemImage: "doc.badge.plus") { read() }
                    .disabled(directory == nil)
            }
            if let errorMessage {
                issue(errorMessage)
            }
        }
        .onChange(of: directory) { _, _ in reset() }
    }

    private var selectionCount: Int { selectedScripts.count + (includeCompose ? 1 : 0) }

    private func candidates(_ result: DefinitionDiscovery.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, message in
                issue(message).padding(Spacing.m)
            }
            if !result.scripts.isEmpty {
                scriptCandidates(result)
            }
            if let compose = result.compose {
                if !result.scripts.isEmpty { Divider() }
                HStack {
                    Text("Docker Compose").font(Typography.heading)
                    Spacer()
                    DiscoveryDetails("Compose の停止範囲") {
                        Text("停止範囲").font(Typography.heading)
                        Text("同じプロジェクト名の全 profile")
                    }
                }
                .padding(Spacing.m)
                HStack(alignment: .top, spacing: Spacing.m) {
                    Toggle(compose.projectName, isOn: $includeCompose)
                        .frame(width: Metrics.discoveryNameWidth, alignment: .leading)
                    Text(compose.files.joined(separator: "\n"))
                        .font(Typography.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Typography.row)
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.m)
            }
            if result.scripts.isEmpty && result.compose == nil && result.issues.isEmpty {
                Label("候補が見つかりません", systemImage: "doc.text.magnifyingglass")
                    .font(Typography.row)
                    .padding(Spacing.l)
            }
            Divider()
            HStack(spacing: Spacing.s) {
                Button("読み込み直す", systemImage: "arrow.clockwise") { read() }
                    .labelStyle(.iconOnly)
                    .help("読み込み直す")
                Spacer()
                Button("キャンセル") { reset() }
                Button("\(selectionCount)件を追加") {
                    do {
                        try add(result, selectedScripts, manager, includeCompose)
                        reset()
                    } catch {
                        errorMessage = String(describing: error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectionCount == 0 || (!selectedScripts.isEmpty && manager == nil))
            }
            .controlSize(.small)
            .padding(Spacing.m)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.separator)
        }
    }

    private func scriptCandidates(_ result: DefinitionDiscovery.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s) {
                Text("package.json").font(Typography.heading)
                Spacer()
                Picker("実行ツール", selection: $manager) {
                    Text("実行ツールを選択").tag(Optional<ScriptPackageManager>.none)
                    ForEach(ScriptPackageManager.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(Optional(value))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                DiscoveryDetails("実行ツールの検出結果") {
                    Text("lockfile").font(Typography.heading)
                    if result.managers.isEmpty {
                        Text("未検出")
                    } else {
                        Text(result.managers.flatMap(\.files).joined(separator: "\n"))
                            .font(Typography.mono)
                    }
                    if let declared = result.declaredPackageManager {
                        Text("packageManager").font(Typography.heading)
                        Text(declared).font(Typography.mono)
                    }
                    Divider()
                    if let manager {
                        Text("\(manager.rawValue) run <script>").font(Typography.mono)
                    }
                    Text("関連する pre/post script も実行される場合があります。コンテナの起動は管理対象スタックに登録してください。")
                }
            }
            .padding(Spacing.m)
            ForEach(result.scripts) { script in
                HStack(alignment: .top, spacing: Spacing.m) {
                    Toggle(script.name, isOn: Binding(
                        get: { selectedScripts.contains(script.name) },
                        set: { selected in
                            if selected { selectedScripts.insert(script.name) }
                            else { selectedScripts.remove(script.name) }
                        }
                    ))
                    .font(Typography.row)
                    .frame(width: Metrics.discoveryNameWidth, alignment: .leading)
                    .help(manager.map { $0.command(script: script.name, directory: result.directory).displayCommandLine }
                          ?? "実行ツールを選択してください")
                    Text(script.body)
                        .font(Typography.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(selectedScripts.contains(script.name) ? Color.accentColor.opacity(0.06) : Color.clear)
            }
            Color.clear.frame(height: Spacing.xs)
        }
    }

    private func issue(_ message: String) -> some View {
        let lines = message.components(separatedBy: "\n")
        return HStack(alignment: .top, spacing: Spacing.s) {
            Label(lines[0], systemImage: "exclamationmark.circle")
                .font(Typography.support)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > 1 {
                DiscoveryDetails("エラーの詳細") {
                    Text(lines.dropFirst().joined(separator: "\n")).font(Typography.mono)
                }
            }
        }
    }

    private func read() {
        reset()
        do {
            guard let directory else { throw DefinitionDiscoveryError("作業ディレクトリを選択してください。") }
            let result = try DefinitionDiscovery.scan(directory: directory)
            preview = result
            manager = result.suggestedManager
        } catch {
            errorMessage = "候補を読み込めません。\n\(error)"
        }
    }

    private func reset() {
        preview = nil
        selectedScripts = []
        manager = nil
        includeCompose = false
        errorMessage = nil
    }
}

private struct DiscoveryDetails<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var isPresented = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Button(title, systemImage: "info.circle") { isPresented = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(title)
            .popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: Spacing.s, content: content)
                    .font(Typography.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Spacing.l)
                    .frame(width: Metrics.discoveryDetailsWidth, alignment: .leading)
            }
    }
}
