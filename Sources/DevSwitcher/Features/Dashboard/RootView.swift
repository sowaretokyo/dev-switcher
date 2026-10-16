import DevSwitcherCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebarMinWidth,
                    ideal: Metrics.sidebarIdealWidth,
                    max: Metrics.sidebarMaxWidth
                )
        } detail: {
            // バナーは詳細ペインの中に置く。NavigationSplitView の外へ積むと
            // タイトルバーとサイドバーの間に全幅の帯が挟まり、サイドバーの頭が押し下がる。
            // safeAreaInset にしないのも同じ理由で、ウィンドウの最小高さを押し上げるため。
            VStack(spacing: 0) {
                BannerArea()
                DetailView()
            }
        }
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        // ツールバーの先頭は稼働中の開発環境そのものにする（`mock.html` の `toolbar()`）。
        // アプリ名はいま見ている画面から自明で、識別情報の前に置くと
        // 「起動中の開発環境はありません Dev Switcher」と読むことになる。
        // ウィンドウ自体の題名は `WindowGroup` に残るので、ウィンドウメニューと
        // Mission Control では引き続き名前で探せる。
        .toolbar(removing: .title)
        // 稼働中の開発環境の識別と操作はツールバーが持つ（DESIGN.md 7章）。
        .toolbar {
            // 読むだけの項目なので、押せるものに見えるガラスの背景を外す。
            ToolbarItem(placement: .navigation) {
                ToolbarIdentity()
            }
            .sharedBackgroundHidden()
            // macOS の primaryAction は左側へ並ぶため、可変の余白を明示する。
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            // 操作はガラスの背景を残す。押せることが見た目で分かる必要がある。
            ToolbarItemGroup(placement: .primaryAction) {
                ToolbarActions()
            }
        }
        .task {
            await state.bootstrap()
        }
        .sheet(item: $state.projectFormPresentation) { presentation in
            ProjectFormView(project: presentation.project)
        }
        .sheet(isPresented: $state.isProjectImportPresented) {
            ProjectImportView()
        }
        .sheet(item: $state.unregisterPresentation) { presentation in
            UnregisterConfirmationSheet(presentation: presentation)
        }
        // 切替中・失敗・引き継ぎはシートで出す。表示中は背後を操作できない（I-1）。
        // 停止を伴う切替だけシートで出す。単純な起動・停止は画面を遮らず、
        // プロジェクト詳細のボタン内で進捗を示す。
        .sheet(item: Binding(get: { state.switchPresentation }, set: { _ in })) { presentation in
            SwitchSheet(initialPresentation: presentation)
        }
        .sheet(item: $state.failurePresentation) { presentation in
            SwitchFailureSheet(presentation: presentation)
        }
        .sheet(
            item: Binding(
                get: { state.supabaseConfirmation },
                set: { if $0 == nil { state.cancelSupabaseConfirmation() } }
            )
        ) { presentation in
            SupabaseConfirmationSheet(presentation: presentation)
        }
        // 引き継ぎシートを閉じる・差し替えるのは AppState だけ。ビュー側の dismiss を
        // 許すと、決着していない手掛かりを抱えたまま画面から消える。
        .sheet(item: Binding(get: { state.handoffPresentation }, set: { _ in })) { presentation in
            HandoffSheet(presentation: presentation)
        }
    }
}

/// 起動不能の原因を黙ってフォールバックせず、常に詳細ペインの上部へ出す。
private struct BannerArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // 再起動直後のDocker未起動などでは複数の警告が同時に出る。
        // その全文を最小高さにするとNavigationSplitView全体が画面外へ押し出される。
        // 短い警告は内容に合わせ、上限を超える場合だけスクロールで全文を読めるようにする。
        ViewThatFits(in: .vertical) {
            banners
            ScrollView {
                banners
            }
        }
        .frame(maxHeight: Metrics.bannerAreaMaxHeight)
        // 空・短文のときは上限いっぱいの空白を取らず、選ばれた内容の高さに合わせる。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var banners: some View {
        VStack(spacing: 0) {
            if let error = state.supabaseObservationError {
                Banner(title: "Supabaseを観測できません", message: error, tint: .orange) {
                    Button("再観測") {
                        Task { await state.applicationDidBecomeActive() }
                    }
                }
            }
            if !state.unregisteredSupabaseObservations.isEmpty {
                Banner(
                    title: "未登録の外部Supabase",
                    message: state.unregisteredSupabaseObservations.map {
                        let label = "\($0.projectID): \($0.state.label)"
                        return $0.detail.map { label + "\n" + $0 } ?? label
                    }.joined(separator: "\n"),
                    tint: .secondary
                ) {
                    EmptyView()
                }
            }
            if let incident = state.runtimeIncident {
                Banner(
                    title: "プロセスが予期せず終了しました",
                    message: "\(incident.serviceName): \(incident.status)",
                    tint: .red,
                    messageLineLimit: 3
                ) {
                    HStack(spacing: Spacing.s) {
                        Button("ログを開く") {
                            state.openLogTarget(
                                .service(
                                    projectID: incident.projectID,
                                    serviceID: incident.serviceID
                                )
                            )
                        }
                        Button("閉じる") { state.dismissRuntimeIncident() }
                    }
                }
            }
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
                    message: "\(hintError)\nアプリ再起動後の引き継ぎや次回保存に影響する可能性があります。原因を解消して再試行してください。",
                    tint: .orange,
                    messageLineLimit: 3
                ) {
                    Button("再試行") {
                        Task { await state.retryLoadingHints() }
                    }
                }
            }
            if let managedHintError = state.managedHintError {
                Banner(
                    title: "Supabaseの状態を再検証できません",
                    message: managedHintMessage(managedHintError),
                    tint: .orange,
                    messageLineLimit: 5
                ) {
                    HStack(spacing: Spacing.s) {
                        if state.hasDiscardableManagedHints {
                            Button("手掛かりを破棄", role: .destructive) {
                                Task { await state.discardUnmatchedManagedHints() }
                            }
                        }
                        Button("再試行") {
                            Task { await state.retryLoadingHints() }
                        }
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

    private func managedHintMessage(_ error: String) -> String {
        var lines = [
            error,
            "該当するSupabaseが起動中か停止中か判定できないため、設定変更と新しい起動を停止しています。",
        ]
        if state.hasDiscardableManagedHints {
            lines.append("保存時の設定を確認してSupabaseを手動停止するか、手掛かりを破棄してください。破棄してもSupabase自体は停止しません。")
        }
        return lines.joined(separator: "\n")
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
        HStack(alignment: .top, spacing: Spacing.s) {
            Circle()
                .fill(tint)
                .frame(width: Metrics.statusDot, height: Metrics.statusDot)
                .padding(.top, Spacing.xs)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(title)
                    .font(Typography.heading)
                Text(message)
                    .font(Typography.support)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }
            Spacer(minLength: Spacing.s)
            accessory()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
