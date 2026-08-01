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
        .sheet(item: $state.residualPrompt) { prompt in
            ResidualSheet(prompt: prompt)
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
                    Button("再読み込み") { state.loadProjects() }
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

/// 通常終了で止まりきらなかったときの確認。既定は安全側（閉じる）。
private struct ResidualSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let prompt: AppState.ResidualPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プロセスが残っています")
                .font(.system(size: 13.5, weight: .semibold))
            Text(situation)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Text("強制終了（SIGKILL）はプロセスの後始末を行わずに停止します。実行するか判断してください。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("強制終了する") {
                    withService { state.forceStop(service: $0) }
                }
                .foregroundStyle(.red)
                Spacer()
                // 通常終了の猶予を使い切った場合以外は、まず通常終了をやり直せるようにする。
                if prompt.cause != .stopTimedOut {
                    Button("通常終了を試す") {
                        withService { service in
                            if let project = state.project(prompt.projectID) {
                                state.stop(service: service, in: project)
                            }
                        }
                    }
                }
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 452)
    }

    private var situation: String {
        switch prompt.cause {
        case .stopTimedOut:
            """
            サービス「\(prompt.serviceName)」は通常終了（SIGTERM）の猶予内に終了しませんでした。
            プロセスグループ \(prompt.processGroupID) にプロセスが残っています。
            """
        case .exitedWithSurvivors:
            """
            サービス「\(prompt.serviceName)」の起動プロセスは終了しましたが、\
            プロセスグループ \(prompt.processGroupID) に別のプロセスが残っています。
            ポートを握ったままの可能性があるため、残っている間はほかのプロジェクトを起動できません。
            """
        case .launchCancelled:
            """
            サービス「\(prompt.serviceName)」の起動は取り消しましたが、\
            プロセスグループ \(prompt.processGroupID) にプロセスが残っています。
            残っている間は、このサービスの再起動とほかのプロジェクトの起動ができません。
            """
        }
    }

    private func withService(_ action: (ServiceDefinition) -> Void) {
        if let project = state.project(prompt.projectID),
           let service = project.service(id: prompt.serviceID) {
            action(service)
        }
        dismiss()
    }
}
