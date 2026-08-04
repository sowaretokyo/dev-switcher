import DevSwitcherCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        // バナーは NavigationSplitView の safeAreaInset にしない。
        // inset にするとウィンドウの最小高さが押し上げられ、既定サイズ 880 × 544 が保てない。
        VStack(spacing: 0) {
            BannerArea()
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 300)
            } detail: {
                DetailView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task {
            await state.bootstrap()
        }
        .sheet(item: $state.projectFormPresentation) { presentation in
            ProjectFormView(project: presentation.project)
        }
        // 切替中・失敗・引き継ぎはシートで出す。表示中は背後を操作できない（I-1）。
        .sheet(item: $state.switchPresentation) { presentation in
            SwitchSheet(initialPresentation: presentation)
        }
        .sheet(item: $state.failurePresentation) { presentation in
            SwitchFailureSheet(presentation: presentation)
        }
        // 引き継ぎシートを閉じる・差し替えるのは AppState だけ。ビュー側の dismiss を
        // 許すと、決着していない手掛かりを抱えたまま画面から消える。
        .sheet(item: Binding(get: { state.handoffPresentation }, set: { _ in })) { presentation in
            HandoffSheet(presentation: presentation)
        }
    }
}

/// 起動不能の原因を黙ってフォールバックせず、常に画面上部へ出す。
private struct BannerArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if let operationError = state.operationError {
                Banner(
                    title: "操作に失敗しました",
                    message: operationError,
                    tint: .red,
                    messageLineLimit: 4
                ) {
                    Button("閉じる") { state.operationError = nil }
                }
            }
            if let storeError = state.storeError {
                Banner(
                    title: "設定を読み込めません",
                    message: storeError,
                    tint: .red
                ) {
                    Button("再読み込み") {
                        Task { await state.retryLoadingProjects() }
                    }
                }
            }
            if let hintError = state.hintError {
                Banner(
                    title: "再検証の手掛かりを扱えません",
                    message: "\(hintError)\nアプリ再起動後の引き継ぎができない可能性があります。稼働中の判定には影響しません。",
                    tint: .orange,
                    messageLineLimit: 3
                ) {
                    Button("再試行") {
                        Task { await state.retryLoadingHints() }
                    }
                }
            }
            switch state.environmentState {
            case .loading:
                Banner(
                    title: "ログインシェルの環境を取得しています",
                    message: "\(LoginShellEnvironment.executable.path) \(LoginShellEnvironment.arguments.joined(separator: " "))",
                    tint: .accentColor
                ) {
                    ProgressView().controlSize(.small)
                }
            case let .failed(reason):
                Banner(
                    title: "ログインシェルの環境を取得できません",
                    message: "\(reason)\n最小限の PATH では起動しません。原因を解消してから再試行してください。",
                    tint: .red
                ) {
                    Button("再試行") {
                        Task { await state.loadEnvironment() }
                    }
                }
            case .ready:
                EmptyView()
            }
        }
    }
}

private struct Banner<Accessory: View>: View {
    let title: String
    let message: String
    let tint: Color
    let messageLineLimit: Int?
    @ViewBuilder let accessory: () -> Accessory

    init(
        title: String,
        message: String,
        tint: Color,
        messageLineLimit: Int? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.message = message
        self.tint = tint
        self.messageLineLimit = messageLineLimit
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
