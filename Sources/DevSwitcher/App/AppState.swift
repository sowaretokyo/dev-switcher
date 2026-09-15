import AppKit
import DevSwitcherCore
import Foundation
import Observation

enum SidebarItem: Hashable, Identifiable {
    case project(UUID)
    case service(projectID: UUID, serviceID: UUID)

    var id: String {
        switch self {
        case let .project(id): "project-\(id.uuidString)"
        case let .service(projectID, serviceID): "service-\(projectID.uuidString)-\(serviceID.uuidString)"
        }
    }

    var projectID: UUID {
        switch self {
        case let .project(id): id
        case let .service(projectID, _): projectID
        }
    }
}

enum AppError: Error, CustomStringConvertible {
    case storeUnavailable(String)
    case projectNotFound(UUID)
    /// いま受け付けられない理由。黙って無視せず、必ず理由を返す。
    case busy(String)

    var description: String {
        switch self {
        case let .storeUnavailable(reason):
            "設定の保存先を利用できません。\n\(reason)"
        case let .projectNotFound(id):
            "編集対象のプロジェクトが見つかりません（\(id.uuidString)）。"
        case let .busy(reason):
            reason
        }
    }
}

/// 排他制御の単位。
///
/// カウンタだと複数の処理が同時に走れてしまい、bootstrap の照合中に起動が始まる。
/// 「いま1件だけ」を token で表し、取得した処理だけが解放できるようにする。
private struct ActivityToken: Equatable {
    let id: UInt64
    let kind: AppState.ActivityKind
}

/// 古いPIDやポートを信用しないよう、稼働状態は保存せず観測結果だけを反映する。
/// 起動・停止・切替はすべて`SwitchCoordinator`を通す。ゲートを迂回する経路を作らない。
@MainActor
@Observable
final class AppState {
    enum EnvironmentState: Equatable {
        case loading
        case ready(searchPathCount: Int)
        case failed(String)
    }

    /// 排他的に実行する処理の種類。理由を画面へ出すために種類まで持つ。
    enum ActivityKind: Equatable, Sendable {
        /// 起動時の読み込みと再検証。
        case bootstrap
        /// 保存済み手掛かりの照合。
        case review
        /// 読み込み・保存の再試行。
        case retry
        /// 起動時に検出したプロセスの決着（そのまま使う／停止する／停止しない）。
        case handoffDecision
        /// 起動・停止・切替・強制終了。
        case operation

        /// ほかの操作を受け付けられない理由。ボタンを黙って無効化しないために使う。
        var blockingDescription: String {
            switch self {
            case .bootstrap:
                "起動時の読み込みと既存プロセスの再検証を実行中です。"
            case .review:
                "既存プロセスを再検証中です。"
            case .retry:
                "再検証の手掛かりを読み直しています。"
            case .handoffDecision:
                "検出した既存プロセスへの操作を実行中です。"
            case .operation:
                "ほかの起動・停止・切替を実行中です。"
            }
        }
    }

    /// 実測状態と管理関係を分け、外部の稼働を停止権限として扱わない。
    struct SupabaseUIState: Equatable {
        let projectID: SupabaseProjectID?
        let state: SupabaseStackState
        let relationship: SupabaseManagementRelationship?
        let detail: String?

        var isExternal: Bool { projectID != nil && relationship == nil && state != .notRunning }

        var label: String {
            isExternal ? "外部・\(state.label)" : state.label
        }
    }

    struct ServiceUIState: Equatable {
        var phase: ServicePhase = .stopped
        var observedPortRecord: ObservedPortRecord = .observed([])
        var observedPorts: [ObservedPort] = []
        var startedAt: Date?
        var warning: String?
        var lastMessage: String?
        var processID: pid_t?
        var processGroupID: pid_t?
        var supabase: SupabaseUIState?

        /// 詳細画面と一覧で共通の観測状態表示。観測不能を空配列へ潰さない。
        var observedPortsAvailabilityText: String? {
            guard phase.isActive else { return "—" }
            guard case let .observed(ports) = observedPortRecord else { return "取得不能" }
            return ports.isEmpty ? "listen なし" : nil
        }
    }

    /// 停止を伴う切替だけをシートで出す。
    ///
    /// 2段階ゲートの進捗と、起動フェーズ前だけ受け付ける中止のためのUI。
    /// 多重操作を止めているのはこのシートではなく `ActivityToken` のAPI境界（DESIGN.md I-1）。
    /// 単純な起動・停止では出さないので、切替元と切替先は必ず存在する。
    struct SwitchPresentation: Identifiable {
        let id = UUID()
        let sourceID: UUID
        let sourceName: String
        let targetID: UUID
        let targetName: String
        var state: SwitchState = .idle
        var cancelRequested = false

        /// 起動フェーズへ入ったら中止は受け付けない（I-4）。
        var canCancel: Bool { !state.hasEnteredStartPhase && !cancelRequested }
    }

    /// シートを出さない単純な起動・停止の進捗。
    ///
    /// 画面を遮らず、利用者が見ているプロジェクトのボタン内で進捗を示す。
    /// 二重操作を防ぐのはこの値ではなく `ActivityToken` なので、
    /// 表示が消えるより先に別の操作が始まることはない。
    struct InlineOperation: Equatable {
        enum Kind: Equatable {
            case starting
            case stopping

            var label: String {
                switch self {
                case .starting: "起動中"
                case .stopping: "停止中"
                }
            }
        }

        let projectID: UUID
        var kind: Kind
        var state: SwitchState = .idle
    }

    /// 通常プロセス1件だけを起動・再起動している間の進捗。
    /// プロジェクト全体の起動・停止とは表示先が違うため、別の型で持つ。
    struct ServiceOperation: Equatable {
        enum Kind: Equatable {
            case starting
            case restarting

            var action: String { self == .starting ? "起動" : "再起動" }
        }

        let projectID: UUID
        let serviceID: UUID
        let kind: Kind
        var state: SwitchState = .idle

        var label: String {
            if case .stopping = state { return "停止中" }
            return kind.action + "中"
        }
    }

    /// 正常起動後に、停止操作なしで終了したプロセスの通知。
    /// 起動失敗は `FailurePresentation` が扱うため、ここでは稼働中の異常終了だけを扱う。
    struct RuntimeIncident: Identifiable, Equatable {
        let id = UUID()
        let projectID: UUID
        let serviceID: UUID
        let serviceName: String
        let status: String
    }

    struct FailurePresentation: Identifiable {
        let id = UUID()
        let failure: SwitchFailure
        /// 「ログを開く」でシートを閉じたあとに選択するサービス。
        let logTarget: SidebarItem?
    }

    /// 既存Supabaseの引き継ぎ・復旧・停止を、1つのシートで確認するための表示値。
    /// 承認するまで既存スタック、切替元、切替先のいずれも変更していない。
    struct SupabaseConfirmationPresentation: Identifiable {
        let id = UUID()
        /// 起動または切替の対象開発環境。
        let projectID: UUID
        let plan: SupabaseConfirmationPlan

        var title: String {
            switch plan.target.action {
            case .adopt: "既存のSupabaseを引き継ぎますか？"
            case .restart: "既存のSupabaseを復旧しますか？"
            case .start, .stop: "既存のSupabaseを停止して切り替えますか？"
            }
        }

        var confirmButtonTitle: String {
            switch plan.target.action {
            case .adopt: "引き継ぐ"
            case .restart: "停止して起動し直す"
            case .start, .stop: "停止して切り替える"
            }
        }

        /// 引き継ぎだけなら既存スタックを止めないため、破壊的な見た目にしない。
        var isDestructive: Bool {
            plan.target.action != .adopt || !plan.stopTargets.isEmpty
        }
    }

    /// 引き継ぎシートで選べる操作。
    /// 候補配列ではなく操作の種類だけを受け取り、対象は`AppState`が現在の判断から取る。
    enum HandoffAction: Equatable, Sendable {
        case adopt
        case stopAll
        case ignore

        var progressDescription: String {
            switch self {
            case .adopt: "そのまま使う準備をしています…"
            case .stopAll: "検出したプロセスを停止しています…"
            case .ignore: "手掛かりを破棄しています…"
            }
        }
    }

    struct HandoffPresentation: Identifiable {
        /// 判断の進行状態。プロセスの`Phase`とは別の型に保つ（DESIGN.md 型で守る）。
        enum Resolution: Equatable {
            case awaiting
            case resolving(HandoffAction)
        }

        let id = UUID()
        let review: HandoffReview
        /// 更新できるのは`AppState`だけ。ビューからは読み取りのみ。
        fileprivate(set) var resolution: Resolution = .awaiting

        var isResolving: Bool { resolution != .awaiting }

        var resolvingDescription: String? {
            guard case let .resolving(action) = resolution else { return nil }
            return action.progressDescription
        }
    }

    struct ProjectFormPresentation: Identifiable {
        let id = UUID()
        let project: ProjectDefinition?
    }

    /// 登録解除の確認。破壊的に見える操作なので、実行前に対象パスを明示する。
    struct UnregisterPresentation: Identifiable {
        let id = UUID()
        let project: ProjectDefinition
    }

    private enum UIEvent: Sendable {
        case service(UUID, ServiceSupervisor.Event)
        /// どの操作の進捗かを識別できるよう、`ActivityToken` の id を持たせる。
        /// 持たせないと、完了した操作の遅れて届いた進捗が次の操作の表示を書き換え、
        /// 「完了」と出たうえに中止も受け付けられなくなる。
        case progress(activityID: UInt64, state: SwitchState)
    }

    /// 手掛かりファイルの読み込み状態。
    /// 「まだ読んでいない」と「読んだ結果が空」を区別しないと、
    /// 起動直後の終了で既存の記録を消してしまう。
    private enum HintLoadState: Equatable {
        case notLoaded
        case loaded
        case failed(String)
    }

    private enum ProjectLoadState: Equatable {
        case notLoaded
        case loaded
        case failed(String)
    }

    private(set) var projects: [ProjectDefinition] = []
    private(set) var serviceStates: [UUID: ServiceUIState] = [:]
    private(set) var projectPhases: [UUID: ProjectPhase] = [:]
    private(set) var unregisteredSupabaseObservations: [SupabaseStackObservation] = []
    private(set) var supabaseObservationError: String?
    /// 表示上の成功・失敗とは分けて、停止対象が1件でも残っているプロジェクトを持つ。
    private var projectIDsWithManagedResources: Set<UUID> = []
    private(set) var logBuffers: [UUID: LogBuffer] = [:]
    private(set) var environmentState: EnvironmentState = .loading
    private(set) var storeError: String?
    private(set) var hintError: String?
    private var hintStorageFailure: String?
    private var hintPortWarning: String?
    private var managedHintFailures: [UUID: String] = [:]
    /// 実行中の排他処理。UIはこれを理由の表示に使う。
    private(set) var activityKind: ActivityKind?
    /// 終了処理に入ったか。入ったあとは新しい処理を受け付けない。
    private(set) var isTerminating = false
    /// 引き継ぎの判断待ち。閉じるのも差し替えるのも`AppState`だけ。
    private(set) var handoffPresentation: HandoffPresentation?
    /// 停止を伴う切替の進捗シート。開閉するのは`AppState`だけ。
    private(set) var switchPresentation: SwitchPresentation?
    /// 単純な起動・停止の進捗。対象プロジェクトの行にだけ出す。
    private(set) var inlineOperation: InlineOperation?
    /// サービス詳細に出す追加起動・再起動の進捗。
    private(set) var serviceOperation: ServiceOperation?
    /// 利用者がまだ閉じていない、直近の予期しないプロセス終了。
    private(set) var runtimeIncident: RuntimeIncident?
    /// 既存Supabaseの扱いについての判断待ち。開閉するのは`AppState`だけ。
    private(set) var supabaseConfirmation: SupabaseConfirmationPresentation?

    var selection: SidebarItem?
    var expandedProjectIDs: Set<UUID> = []
    var projectFormPresentation: ProjectFormPresentation?
    var isProjectImportPresented = false
    var unregisterPresentation: UnregisterPresentation?
    var operationError: String?
    var failurePresentation: FailurePresentation?

    private let registry: RuntimeRegistry
    private let coordinator: SwitchCoordinator
    private let handoffInspector: HandoffInspector
    private var store: ProjectStore?
    private let projectStoreFactory: @Sendable () throws -> ProjectStore
    private let hintStoreFactory: @Sendable () throws -> any RuntimeHintPersisting
    /// 手掛かりの保存先。利用できない理由も型で持つ。
    /// nil を「保存先なし＝成功」と扱うと、書き出せないまま終了できてしまう。
    private enum HintStorage {
        case available(any RuntimeHintPersisting)
        case unavailable(reason: String)
    }
    private var hintStorage: HintStorage
    /// 利用者へ提示したが、まだ決着していない手掛かり。
    ///
    /// 引き継ぎや停止に失敗した候補をここへ残す。`RuntimeRegistry` は失敗した候補を
    /// 管理下に持たないため、これを持たずに保存し直すと、実際には残っているプロセスの
    /// 手掛かりを空の一覧で消してしまう。ポートを持たない孫プロセスは以後検出できない。
    private var pendingHints: [UUID: RuntimeHint] = [:]
    /// まだ安全な錨へ変換できていない旧形式の記録。変換できるまで捨てずに持ち回る。
    /// 同じ`serviceID`が`pendingHints`と両方に載ることは無い（変換済みなら現行形式が正）。
    private var pendingLegacyHints: [UUID: LegacyRuntimeHint] = [:]
    /// managed commandはPIDを持たないため、statusで再検証できるまで別に保持する。
    private var pendingManagedHints: [UUID: ManagedRuntimeHint] = [:]
    /// 手掛かりの読み込み状態。読み込めていない状態で保存すると、
    /// 既存の記録を空の一覧で上書きしてしまう。
    private var hintLoadState: HintLoadState = .notLoaded
    private var projectLoadState: ProjectLoadState = .notLoaded
    /// 実行中の排他処理を識別する token。解放できるのは取得した処理だけ。
    private var currentToken: ActivityToken?
    private var activityCounter: UInt64 = 0
    private let eventContinuation: AsyncStream<UIEvent>.Continuation
    private let eventStream: AsyncStream<UIEvent>
    private var eventPump: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    /// 保存先と実行環境はテストから差し替えられるようにする。
    /// 既定のままだと、テストが利用者の Application Support（設定・手掛かり・ログ）を
    /// 書き換えてしまう。`RuntimeRegistry` はログの出力先を持つので、これも注入する。
    init(
        registry: RuntimeRegistry = RuntimeRegistry(),
        store: ProjectStore? = nil,
        hintStore: (any RuntimeHintPersisting)? = nil,
        projectStoreFactory: @escaping @Sendable () throws -> ProjectStore = {
            try ProjectStore.defaultStore()
        },
        hintStoreFactory: @escaping @Sendable () throws -> any RuntimeHintPersisting = {
            try RuntimeHintStore.defaultStore()
        },
        handoffInspector: HandoffInspector = HandoffInspector(),
        coordinatorOptions: SwitchCoordinator.Options = SwitchCoordinator.Options()
    ) {
        let (stream, continuation) = AsyncStream<UIEvent>.makeStream(
            of: UIEvent.self,
            bufferingPolicy: .unbounded
        )
        eventStream = stream
        eventContinuation = continuation
        self.registry = registry
        self.projectStoreFactory = projectStoreFactory
        self.hintStoreFactory = hintStoreFactory
        self.handoffInspector = handoffInspector
        // 切替は必ず同じ registry を使う。別インスタンスにすると、
        // 起動したプロセスと停止対象がずれる。
        coordinator = SwitchCoordinator(registry: registry, options: coordinatorOptions)

        if let store {
            self.store = store
        } else {
            do {
                self.store = try projectStoreFactory()
            } catch {
                storeError = "\(error)"
            }
        }
        if let hintStore {
            self.hintStorage = .available(hintStore)
        } else {
            do {
                self.hintStorage = .available(try hintStoreFactory())
            } catch {
                self.hintStorage = .unavailable(reason: "\(error)")
                hintStorageFailure = "\(error)"
                refreshHintError()
            }
        }

        // 生成した時点から受け口を開けておく。開始を呼び出し側の手順に委ねると、
        // 呼び忘れたぶんのログと終了イベントが黙って捨てられる。
        startEventPump()
    }

    var storeLocation: String {
        store?.fileURL.path ?? "未設定"
    }

    private func refreshHintError() {
        hintError = [hintStorageFailure, hintPortWarning]
            .compactMap { $0 }
            .joined(separator: "\n")
        if hintError?.isEmpty == true { hintError = nil }
    }

    /// managed commandの再検証失敗は、通常のPID手掛かりとは起動判定への影響が異なる。
    /// 同じバナー文言へ混ぜず、Supabaseの状態を判定できないことを明示する。
    var managedHintError: String? {
        let messages = managedHintFailures
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map(\.value)
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    var hasDiscardableManagedHints: Bool {
        !discardableManagedHintIDs.isEmpty
    }

    private var discardableManagedHintIDs: Set<UUID> {
        Set(pendingManagedHints.values.compactMap { hint in
            guard let service = project(hint.projectID)?.service(id: hint.serviceID),
                  service.kind == .supabase else {
                return hint.serviceID
            }
            guard let configuration = service.supabaseConfiguration,
                  let currentProjectID = try? configuration.resolveProjectID() else {
                return hint.serviceID
            }
            return hint.matchesConfiguration(
                of: service,
                currentProjectID: currentProjectID
            ) ? nil : hint.serviceID
        })
    }

    var canStartServices: Bool {
        if case .ready = environmentState { return true }
        return false
    }

    /// 同時に稼働できるプロジェクトは1つ。実際に資源を握っているものを稼働中とみなす。
    var activeProject: ProjectDefinition? {
        projects.first { hasManagedResources(in: $0) }
    }

    /// Dev Switcherが停止できるプロセスまたは残存グループがあるか。
    /// 成功・失敗などの表示状態を、停止導線や設定変更権限の判定へ流用しない。
    func hasManagedResources(in project: ProjectDefinition) -> Bool {
        projectIDsWithManagedResources.contains(project.id)
    }

    // MARK: - 起動時

    func bootstrap() async {
        guard let token = beginActivity(.bootstrap) else { return }
        defer { endActivity(token) }

        loadProjectsFromStore()
        // 最初の await より前に手掛かりを読み込む。読み込む前に終了要求が来ると、
        // 「まだ読んでいない」状態のまま空の一覧を保存して既存の記録を失う。
        ensureHintsLoaded()
        // 保存値から稼働中を決めつけない。最初の表示も実プロセスの観測から組み立てる。
        await refreshPhases()
        await reloadEnvironment()
        await restoreManagedHints()
        await reviewLoadedHints()
    }

    // MARK: - 排他制御

    /// 排他的に処理を始める。取得できなければ何も変更せず nil を返す。
    ///
    /// 取得の前に pending・シート・読み込み状態・操作状態を変えてはいけない。
    /// 変えてから取得に失敗すると、実行していない処理の痕跡だけが残る。
    private func beginActivity(_ kind: ActivityKind) -> ActivityToken? {
        guard !isTerminating, currentToken == nil else { return nil }
        activityCounter += 1
        let token = ActivityToken(id: activityCounter, kind: kind)
        currentToken = token
        activityKind = kind
        return token
    }

    private func endActivity(_ token: ActivityToken) {
        guard currentToken == token else { return }
        currentToken = nil
        activityKind = nil
    }

    /// 取得した token のまま非同期処理を実行する。完了時に必ず解放する。
    private func runActivity(_ token: ActivityToken, _ body: @escaping () async -> Void) {
        operationTask = Task {
            await body()
            endActivity(token)
        }
    }

    /// 実行中の処理があるか。UI は「処理中」の表示に使う。
    var isOperationInFlight: Bool { activityKind != nil }

    /// 手掛かりを読み込む。読み込み済みなら何もしない。
    ///
    /// 同期処理なので、呼んだ時点で状態が確定する（await をまたがない）。
    /// ここだけは排他を取らない。排他を持つ処理自身が最初にこれを呼ぶため、
    /// 取らせると読み込みが常に失敗する。
    @discardableResult
    func ensureHintsLoaded() -> Bool {
        switch hintLoadState {
        case .loaded:
            return true
        case .failed:
            return false
        case .notLoaded:
            guard case let .available(hintStore) = hintStorage else {
                if case let .unavailable(reason) = hintStorage {
                    // 保存先が無いことを成功として扱わない。書き出せないまま終了させない。
                    hintLoadState = .failed(reason)
                    hintStorageFailure = reason
                    refreshHintError()
                }
                return false
            }
            do {
                let load = try hintStore.load()
                // 照合の前に保持する。照合の途中で終了要求が来ても記録を失わない。
                for hint in load.hints {
                    pendingHints[hint.serviceID] = hint
                }
                for legacy in load.legacy {
                    pendingLegacyHints[legacy.serviceID] = legacy
                }
                for managed in load.managed {
                    pendingManagedHints[managed.serviceID] = managed
                }
                hintLoadState = .loaded
                hintStorageFailure = nil
                refreshHintError()
                return true
            } catch {
                hintLoadState = .failed("\(error)")
                hintStorageFailure = "\(error)"
                refreshHintError()
                return false
            }
        }
    }

    /// 読み込み・保存の再試行。利用者が明示的に選んだときだけ状態を戻す。
    ///
    /// 失敗の種類ごとに再試行の内容を変える。読めているのに保存だけ失敗している状態で
    /// 読み直すだけだと、利用者が原因を解消しても `hintError` が消えない。
    func retryLoadingHints() async {
        // 取得する前に factory も読み込み状態も触らない。
        guard let token = beginActivity(.retry) else { return }
        defer { endActivity(token) }

        if case .unavailable = hintStorage {
            do {
                hintStorage = .available(try hintStoreFactory())
                hintStorageFailure = nil
                refreshHintError()
            } catch {
                let reason = "\(error)"
                hintStorage = .unavailable(reason: reason)
                hintLoadState = .failed(reason)
                hintStorageFailure = reason
                refreshHintError()
                return
            }
        }
        if case .failed = hintLoadState {
            hintLoadState = .notLoaded
        }
        guard ensureHintsLoaded() else { return }

        await restoreManagedHints()
        if pendingHints.isEmpty, pendingLegacyHints.isEmpty {
            // 再検証する対象が無い。保存だけが失敗している場合に備え、
            // 管理中サービスを含む完全なスナップショットを保存し直す。
            await persistRuntimeHints()
        } else {
            await reviewLoadedHints()
        }
    }

    private func startEventPump() {
        guard eventPump == nil else { return }
        // ログの順序を崩さないよう、UIへの反映は1本のストリームで直列に処理する。
        eventPump = Task { [weak self] in
            guard let stream = self?.eventStream else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .service(serviceID, serviceEvent):
                    self.apply(serviceEvent, to: serviceID)
                    // 稼働開始後にプロセスが落ちた場合、サービス行だけ失敗にして
                    // プロジェクトを「稼働中」のままにしない。一部停止も同じ経路で反映する。
                    if case .exited = serviceEvent {
                        await self.refreshPhases()
                    }
                case let .progress(activityID, state):
                    // 終わった操作の進捗は副作用なしで捨てる。反映すると、次の操作が
                    // いきなり完了表示になり、起動フェーズ前でも中止が効かなくなる。
                    guard self.currentActivityID == activityID else { break }
                    // 進捗は、切替シート・環境全体・プロセス単体の該当する表示先へ流す。
                    self.switchPresentation?.state = state
                    self.inlineOperation?.state = state
                    self.serviceOperation?.state = state
                    await self.refreshPhases()
                }
            }
        }
    }

    /// 設定を読み直す。照合はしない。
    /// 手掛かりの照合と同時に走らせない。読み込み途中の定義で照合すると、
    /// 定義があるのに「定義欠落」と判定されうる。
    @discardableResult
    func loadProjects() -> Bool {
        guard let token = beginActivity(.retry) else { return false }
        defer { endActivity(token) }
        loadProjectsFromStore()
        return projectLoadState == .loaded
    }

    /// 呼び出し側が activity を持っている前提の読み込み。
    private func loadProjectsFromStore() {
        if store == nil {
            do {
                store = try projectStoreFactory()
            } catch {
                let reason = "\(error)"
                storeError = reason
                projectLoadState = .failed(reason)
                return
            }
        }
        guard let store else { return }
        do {
            projects = try store.load()
            storeError = nil
            projectLoadState = .loaded
            if selection == nil, let first = projects.first {
                selection = .project(first.id)
                expandedProjectIDs.insert(first.id)
            }
        } catch {
            storeError = "\(error)"
            projectLoadState = .failed("\(error)")
        }
    }

    /// 設定の読み込みに失敗したあと、同じAppState上で保存済みhintのレビューまで再開する。
    /// 終了処理へ入った後は、終了直前のhint保存と競合するため開始しない。
    func retryLoadingProjects() async {
        guard let token = beginActivity(.retry) else { return }
        defer { endActivity(token) }

        loadProjectsFromStore()
        guard projectLoadState == .loaded else { return }
        await restoreManagedHints()
        await reviewLoadedHints()
    }

    /// ログインシェル環境の再取得。利用者がバナーから明示的に選んだときに呼ぶ。
    func loadEnvironment() async {
        guard let token = beginActivity(.retry) else { return }
        defer { endActivity(token) }
        await reloadEnvironment()
        await restoreManagedHints()
    }

    /// アプリがフォアグラウンドへ戻ったときの再観測。
    ///
    /// 表示更新と手掛かりの自動再検証だけを行い、確認表示・引き継ぎ・停止はしない
    /// （`MVP_SPEC.md` 11、`DESIGN.md` 決定 j）。
    func applicationDidBecomeActive() async {
        guard !isTerminating, activityKind == nil else { return }
        guard let token = beginActivity(.review) else { return }
        defer { endActivity(token) }
        await restoreManagedHints()
    }

    /// 呼び出し側が activity を持っている前提の再取得。
    private func reloadEnvironment() async {
        environmentState = .loading
        do {
            let environment = try await registry.environment(reload: true)
            environmentState = .ready(searchPathCount: environment.searchPath.count)
        } catch {
            environmentState = .failed("\(error)")
        }
    }

    // MARK: - 引き継ぎ

    /// 保存済みの手掛かりを実測と突き合わせる。ここでは何も起動・停止しない。
    /// 一致した候補を提示するだけで、引き継ぐかどうかは利用者が決める。
    func reviewHandoffCandidates() async {
        guard let token = beginActivity(.review) else { return }
        defer { endActivity(token) }
        ensureHintsLoaded()
        await reviewLoadedHints()
    }

    /// 読み込み済みの手掛かりを照合する。呼び出し側が activity を管理する。
    private func reviewLoadedHints() async {
        guard hintLoadState == .loaded, projectLoadState == .loaded else { return }

        // 定義が無い手掛かりは、プロセス不存在を意味しない。照合対象から分けるが破棄しない。
        let knownHints = pendingHints.values.filter { hint in
            project(hint.projectID)?.service(id: hint.serviceID) != nil
        }
        let knownLegacy = pendingLegacyHints.values.filter { legacy in
            project(legacy.projectID)?.service(id: legacy.serviceID) != nil
        }
        guard !pendingHints.isEmpty || !pendingLegacyHints.isEmpty else { return }

        let missingCurrent = pendingHints.values
            .filter { hint in project(hint.projectID)?.service(id: hint.serviceID) == nil }
            .map { hint in
                HandoffRejectionRecord.current(
                    hint: hint,
                    reason: .definitionMissing(
                        projectID: hint.projectID,
                        serviceID: hint.serviceID
                    )
                )
            }
        let missingLegacy = pendingLegacyHints.values
            .filter { hint in project(hint.projectID)?.service(id: hint.serviceID) == nil }
            .map { hint in
                HandoffRejectionRecord.legacy(
                    hint: hint,
                    reason: .definitionMissing(
                        projectID: hint.projectID,
                        serviceID: hint.serviceID
                    )
                )
            }

        await presentReview(
            of: RuntimeHintsLoad(
                hints: knownHints.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString },
                legacy: knownLegacy.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }
            ),
            additionalRejections: missingCurrent + missingLegacy
        )
    }

    /// Supabaseの手掛かりを、保存値ではなく実測（Docker inventory＋status）で再検証する。
    ///
    /// 確認表示も引き継ぎも停止もしない。一致したものだけを`restored`として管理下へ戻し、
    /// 判定できないものは捨てずに理由とともに残す（`MVP_SPEC.md` 11）。
    private func restoreManagedHints() async {
        guard projectLoadState == .loaded,
              case .ready = environmentState else { return }

        // 管理下のSupabaseは、手掛かりが無くてもフォアグラウンド復帰のたび実測し直す。
        let managedBeforeObservation = await registry.managedSupabaseProjectIDs()
        _ = await coordinator.observeSupabaseStacks(registeredProjects: projects)
        guard hintLoadState == .loaded, !pendingManagedHints.isEmpty else {
            await refreshPhases()
            if hintLoadState == .loaded,
               await registry.managedSupabaseProjectIDs() != managedBeforeObservation {
                // 停止確認で失効した手掛かりをディスクにも残さず、次回の自動復元を防ぐ。
                _ = await saveCompleteHintSnapshot(
                    pendingHints: pendingHints,
                    pendingLegacyHints: pendingLegacyHints
                )
            }
            return
        }

        var remaining = pendingManagedHints
        var failures: [UUID: String] = [:]
        for hint in pendingManagedHints.values.sorted(by: {
            $0.serviceID.uuidString < $1.serviceID.uuidString
        }) {
            guard let project = project(hint.projectID),
                  let service = project.service(id: hint.serviceID),
                  service.kind == .supabase else {
                failures[hint.serviceID] = "\(hint.serviceName): 対応するSupabase設定が見つからないため状態を確認できません。"
                continue
            }
            switch await coordinator.restoreManagedStack(
                hint: hint,
                service: service,
                in: project,
                registeredProjects: projects
            ) {
            case .restored, .notRunning:
                remaining[hint.serviceID] = nil
            case let .skipped(reason):
                failures[hint.serviceID] = "\(service.name): \(reason)"
            }
        }
        pendingManagedHints = remaining
        managedHintFailures = failures
        await refreshPhases()

        let managedAfterObservation = await registry.managedSupabaseProjectIDs()
        if failures.isEmpty || managedBeforeObservation != managedAfterObservation {
            _ = await saveCompleteHintSnapshot(
                pendingHints: pendingHints,
                pendingLegacyHints: pendingLegacyHints
            )
        }
    }

    /// 対応する設定が無いか保存時と一致しないmanaged hintを、利用者の明示操作で破棄する。
    /// 保存に成功するまでメモリ側は変更せず、破棄したつもりで次回また現れないようにする。
    func discardUnmatchedManagedHints() async {
        guard let token = beginActivity(.handoffDecision) else { return }
        defer { endActivity(token) }
        guard ensureHintsLoaded() else { return }

        let discardedIDs = discardableManagedHintIDs
        guard !discardedIDs.isEmpty else { return }
        let remaining = pendingManagedHints.filter { !discardedIDs.contains($0.key) }
        guard await saveCompleteHintSnapshot(
            pendingHints: pendingHints,
            pendingLegacyHints: pendingLegacyHints,
            pendingManagedHints: remaining
        ) else { return }

        pendingManagedHints = remaining
        for serviceID in discardedIDs {
            managedHintFailures[serviceID] = nil
        }
    }

    /// 決着していない手掛かりを再検証し、必要なら判断を求め直す。
    private func presentReview(
        of load: RuntimeHintsLoad,
        additionalRejections: [HandoffRejectionRecord] = []
    ) async {
        let inspected = await handoffInspector.review(load)
        let review = HandoffReview(
            candidates: inspected.candidates,
            stoppable: inspected.stoppable,
            rejected: inspected.rejected + additionalRejections
        )
        // 決着するまで手掛かりを保持する。ここで保持しないと、直後の保存で
        // 実際には残っているプロセスの手掛かりが消える。
        // 照合で安全な錨へ変換できたものは、旧形式の側から外す。
        var reviewedHints: [UUID: RuntimeHint] = [:]
        for hint in review.candidates.map(\.hint) + review.stoppable.map(\.hint) {
            reviewedHints[hint.serviceID] = hint
        }
        // 捨ててよいと確認できていない記録も持ち越す。観測できなかっただけのものや、
        // 安全な錨へ変換できていない旧形式を消すと、残っているプロセスを見失う。
        var carriedLegacy: [UUID: LegacyRuntimeHint] = [:]
        for record in review.unresolvedRejections {
            switch record {
            case let .current(hint, _):
                if reviewedHints[hint.serviceID] == nil {
                    reviewedHints[hint.serviceID] = hint
                }
            case let .legacy(hint, _):
                carriedLegacy[hint.serviceID] = hint
            }
        }
        for serviceID in reviewedHints.keys {
            carriedLegacy[serviceID] = nil
        }

        // 確実に古いhintの削除も、管理中サービスを含む完全なスナップショットで行う。
        // 保存が失敗した場合はメモリ側を先に進めず、次の再試行で同じ入力を再検証する。
        if await saveCompleteHintSnapshot(
            pendingHints: reviewedHints,
            pendingLegacyHints: carriedLegacy
        ) {
            pendingHints = reviewedHints
            pendingLegacyHints = carriedLegacy
        }

        let decisionReview = HandoffReview(
            candidates: review.candidates,
            stoppable: review.stoppable,
            rejected: review.unresolvedRejections
        )
        handoffPresentation = review.needsDecision
            ? HandoffPresentation(review: decisionReview)
            : nil
    }

    /// 引き継ぎシートの選択。いま表示している判断に対して、1回だけ効く。
    ///
    /// 対象は`AppState`が現在の判断から取る。ビューから候補配列を受け取ると、
    /// 古い提示や二重クリックから別の操作を始められてしまう。
    func performHandoffAction(_ action: HandoffAction, presentationID: UUID) {
        // 古い presentation.id・2回目の操作は、副作用なしで拒否する。
        guard let presentation = handoffPresentation,
              presentation.id == presentationID,
              presentation.resolution == .awaiting
        else { return }

        guard let token = beginActivity(.handoffDecision) else {
            operationError = (activityKind?.blockingDescription ?? "ほかの処理を実行中です。")
                + "\n完了してからもう一度選んでください。"
            return
        }
        // 取得できたときだけ、同期的に awaiting → resolving へ移す。
        handoffPresentation?.resolution = .resolving(action)

        let review = presentation.review
        runActivity(token) { [self] in
            switch action {
            case .adopt:
                await adopt(review.candidates)
            case .stopAll:
                await stopDetected(review.candidates, stoppable: review.stoppable)
            case .ignore:
                await ignorePendingHints()
            }
        }
    }

    /// 決着させる対象を、画面で検証済みの現行形式の手掛かりへ寄せる。
    ///
    /// 旧形式から変換した候補は、ここで必ず旧形式側から外す。外さないと、
    /// 移行時の保存に失敗していた場合に、決着済みのサービスが再変換されて再提示される。
    private func claimPending(_ hints: [RuntimeHint]) {
        for hint in hints {
            pendingHints[hint.serviceID] = hint
            pendingLegacyHints[hint.serviceID] = nil
        }
    }

    /// 候補を引き継ぐ。初期観測まで通ったものだけを起動済みとして表示する。
    private func adopt(_ candidates: [HandoffCandidate]) async {
        claimPending(candidates.map(\.hint))

        var failures: [String] = []
        for candidate in candidates {
            guard let project = project(candidate.hint.projectID),
                  let service = project.service(id: candidate.hint.serviceID)
            else { continue }
            do {
                try await coordinator.adopt(candidate, service: service, in: project)
                // 管理下に入ったので、以後は実測から手掛かりを作り直せる。
                pendingHints[candidate.hint.serviceID] = nil
            } catch {
                // 検証してからボタンを押すまでの間に本体が終了していることがある。
                // 失敗した候補の手掛かりは捨てず、再検証して選び直せるようにする。
                failures.append("\(service.name): \(error)")
            }
        }

        if !failures.isEmpty {
            operationError = "そのまま使えないサービスがあります。\n"
                + failures.joined(separator: "\n")
        }
        await refreshPhases()
        await persistRuntimeHints()
        await settleHandoff()
    }

    /// 候補を停止する。利用者が明示的に選んだ場合にだけ呼ぶ。
    private func stopDetected(
        _ candidates: [HandoffCandidate],
        stoppable: [StoppableProcessFinding]
    ) async {
        // 停止に失敗したものの手掛かりも残す。消えると次回検出できなくなる。
        claimPending(candidates.map(\.hint) + stoppable.map(\.hint))

        var failures: [String] = []
        for candidate in candidates {
            guard let project = project(candidate.hint.projectID),
                  let service = project.service(id: candidate.hint.serviceID)
            else { continue }
            do {
                let outcome = try await coordinator.stopAdopted(
                    candidate,
                    service: service,
                    in: project
                )
                switch outcome {
                case let .residual(_, reason), let .ownershipLost(reason):
                    failures.append("\(service.name): \(reason)")
                case .stopped:
                    pendingHints[candidate.hint.serviceID] = nil
                }
            } catch {
                failures.append("\(service.name): \(error)")
            }
        }

        for finding in stoppable {
            guard let project = project(finding.hint.projectID),
                  let service = project.service(id: finding.hint.serviceID)
            else { continue }
            do {
                let outcome = try await coordinator.stopWithoutAdopting(
                    finding,
                    service: service,
                    in: project
                )
                switch outcome {
                case let .residual(_, reason), let .ownershipLost(reason):
                    failures.append("\(service.name): \(reason)")
                case .stopped:
                    pendingHints[finding.hint.serviceID] = nil
                }
            } catch {
                failures.append("\(service.name): \(error)")
            }
        }

        // 1件でも止まらなければ黙って終わらせない。
        if !failures.isEmpty {
            operationError = "停止できなかったプロセスがあります。\n"
                + failures.joined(separator: "\n")
        }
        await refreshPhases()
        await persistRuntimeHints()
        await settleHandoff()
    }

    /// 無視する。管理中サービスの手掛かりは残し、未決着の手掛かりだけを破棄する。
    /// 完全なスナップショットを保存できた場合だけメモリとシートを更新する。
    private func ignorePendingHints() async {
        guard ensureHintsLoaded() else {
            handoffPresentation?.resolution = .awaiting
            return
        }
        guard await saveCompleteHintSnapshot(
            pendingHints: [:],
            pendingLegacyHints: [:]
        ) else {
            // 破棄できなければ何も捨てない。同じ判断画面へ戻し、やり直せるようにする。
            handoffPresentation?.resolution = .awaiting
            return
        }

        pendingHints = [:]
        pendingLegacyHints = [:]
        handoffPresentation = nil
    }

    /// 決着しなかった手掛かりが残っていれば、実測し直して判断を求め直す。
    private func settleHandoff() async {
        guard !pendingHints.isEmpty || !pendingLegacyHints.isEmpty else {
            handoffPresentation = nil
            return
        }
        guard hintLoadState == .loaded, projectLoadState == .loaded else {
            // 再検証できないので、同じ判断画面へ戻して再実行できるようにする。
            handoffPresentation?.resolution = .awaiting
            return
        }
        await reviewLoadedHints()
    }

    // MARK: - プロジェクト

    func project(_ id: UUID) -> ProjectDefinition? {
        projects.first { $0.id == id }
    }

    func addProject(_ project: ProjectDefinition) throws {
        if let reason = configurationBlockedReason { throw AppError.busy(reason) }
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        try store.save(projects + [project])
        projects.append(project)
        expandedProjectIDs.insert(project.id)
        selection = .project(project.id)
    }

    func presentProjectImport() {
        if let reason = configurationBlockedReason {
            operationError = "開発環境を取り込めません。\n\(reason)"
            return
        }
        isProjectImportPresented = true
    }

    func previewProjectImport(_ data: Data, path: String) throws -> [ProjectDefinition] {
        if let reason = configurationBlockedReason { throw AppError.busy(reason) }
        return try ProjectStore.projectsForImport(data, path: path, existingProjects: projects)
    }

    /// 全件を再検証して1回で保存する。途中の1件だけを登録した状態を作らない。
    /// 同期処理なので、既存の設定変更と同様に確認から保存まで別操作を挟まない。
    func importProjects(_ imported: [ProjectDefinition]) throws {
        if let reason = configurationBlockedReason { throw AppError.busy(reason) }
        guard let first = imported.first else { throw ProjectStoreError.emptyImport }
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        let updated = projects + imported
        try store.save(updated)
        projects = updated
        expandedProjectIDs.formUnion(imported.map(\.id))
        selection = .project(first.id)
        isProjectImportPresented = false
    }

    func updateProject(_ project: ProjectDefinition) throws {
        if let reason = configurationBlockedReason(for: project) { throw AppError.busy(reason) }
        try applyProjectUpdate(project)
    }

    private func applyProjectUpdate(_ project: ProjectDefinition) throws {
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw AppError.projectNotFound(project.id)
        }

        let previous = projects[index]
        var updatedProjects = projects
        updatedProjects[index] = project
        try store.save(updatedProjects)
        projects = updatedProjects

        // 編集で消えたサービスの画面状態を残さない。ログの実ファイルには触らない。
        let remaining = Set(project.services.map(\.id))
        for service in previous.services where !remaining.contains(service.id) {
            serviceStates[service.id] = nil
            logBuffers[service.id] = nil
            if case let .service(_, serviceID) = selection, serviceID == service.id {
                selection = .project(project.id)
            }
        }
    }

    /// Dev Switcher の登録から外す。ローカルのリポジトリ・ファイル・ログには一切触らない。
    ///
    /// 保存に成功してからメモリ上の一覧を変更する。先にメモリを変えると、保存が失敗した
    /// ときに「画面からは消えたのに設定ファイルには残っている」状態になり、次回起動で復活する。
    func unregisterProject(_ project: ProjectDefinition) throws {
        if let reason = configurationBlockedReason(for: project) { throw AppError.busy(reason) }
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw AppError.projectNotFound(project.id)
        }

        var updatedProjects = projects
        let removed = updatedProjects.remove(at: index)
        try store.save(updatedProjects)
        projects = updatedProjects

        // 消えたプロジェクトを指す画面状態を残さない。
        expandedProjectIDs.remove(removed.id)
        projectPhases[removed.id] = nil
        projectIDsWithManagedResources.remove(removed.id)
        for service in removed.services {
            serviceStates[service.id] = nil
            logBuffers[service.id] = nil
        }
        if selection?.projectID == removed.id {
            selection = projects.first.map { SidebarItem.project($0.id) }
            if let first = projects.first { expandedProjectIDs.insert(first.id) }
        }
        unregisterPresentation = nil
    }

    /// 登録解除の確認を出す。拒否理由はここでも API 境界と同じ判断を使う。
    func presentUnregisterConfirmation(for project: ProjectDefinition) {
        if let reason = configurationBlockedReason(for: project) {
            operationError = "プロジェクトの登録を解除できません。\n\(reason)"
            return
        }
        unregisterPresentation = UnregisterPresentation(project: project)
    }

    func canUnregister(_ project: ProjectDefinition) -> Bool {
        configurationBlockedReason(for: project) == nil
    }

    func presentProjectForm(editing project: ProjectDefinition? = nil) {
        // 新規追加は稼働中プロジェクトの影響を受けないが、設定を読めていない状態では
        // 追加も拒否する。読めていない一覧へ足して保存すると既存の定義を失う。
        let blocked = project.map { configurationBlockedReason(for: $0) }
            ?? configurationBlockedReason
        if let blocked {
            operationError = "プロジェクト設定を変更できません。\n\(blocked)"
            return
        }
        projectFormPresentation = ProjectFormPresentation(project: project)
    }

    func canEdit(_ project: ProjectDefinition) -> Bool {
        configurationBlockedReason(for: project) == nil
    }

    /// 今回の起動対象を切り替える。設定なので永続化する（稼働状態ではない）。
    func setEnabledNow(_ enabled: Bool, for service: ServiceDefinition, in project: ProjectDefinition) {
        applyProjectChange(project.settingEnabledNow(service.id, to: enabled))
    }

    /// 「既定に戻す」。明示指定を消して`enabledByDefault`に従わせる。
    func resetEnabledNow(in project: ProjectDefinition) {
        applyProjectChange(project.clearingEnabledNow())
    }

    private func applyProjectChange(_ updated: ProjectDefinition) {
        if let reason = configurationBlockedReason(for: updated) {
            operationError = "プロジェクト設定を変更できません。\n\(reason)"
            return
        }
        do {
            try applyProjectUpdate(updated)
            operationError = nil
            Task { await refreshPhases() }
        } catch {
            operationError = "\(error)"
        }
    }

    func state(of serviceID: UUID) -> ServiceUIState {
        serviceStates[serviceID] ?? ServiceUIState()
    }

    func logBuffer(of serviceID: UUID) -> LogBuffer {
        if let buffer = logBuffers[serviceID] { return buffer }
        let buffer = LogBuffer()
        logBuffers[serviceID] = buffer
        return buffer
    }

    func markLogAsRead(serviceID: UUID) {
        logBuffer(of: serviceID).markStderrAsRead()
    }

    func phase(of project: ProjectDefinition) -> ProjectPhase {
        // 実測だけでは、順番に停止している途中と一部の異常終了を区別できない。
        // 操作中だけ意図した遷移を優先し、完了後は再びCoordinatorの実測へ戻す。
        if let inlineOperation, inlineOperation.projectID == project.id {
            switch inlineOperation.state {
            case .rollingBack:
                return .stopping
            case .completed:
                break
            default:
                return inlineOperation.kind == .starting ? .starting : .stopping
            }
        }
        if let switchPresentation {
            if switchPresentation.sourceID == project.id {
                switch switchPresentation.state {
                case .stopping, .verifyingRelease:
                    return .stopping
                default:
                    break
                }
            }
            if switchPresentation.targetID == project.id {
                switch switchPresentation.state {
                case .starting, .observingStartup:
                    return .starting
                case .rollingBack:
                    return .stopping
                default:
                    break
                }
            }
        }
        return projectPhases[project.id] ?? .stopped
    }

    // MARK: - 受け付けられない理由

    /// 手掛かりを扱えない状態。新しいプロセスを起動してはいけない。
    ///
    /// 読み込めない・保存できない状態で起動すると、そのプロセスの手掛かりを残せない。
    /// ポートを持たないサービスは、次回起動時に検出も停止もできなくなる。
    private var runtimeHintBlockReason: String? {
        switch hintLoadState {
        case .notLoaded:
            return "再検証の手掛かりをまだ読み込んでいません。"
        case let .failed(reason):
            return "再検証の手掛かりを読み込めません。\n\(reason)"
        case .loaded:
            break
        }
        if case let .unavailable(reason) = hintStorage {
            return "再検証の手掛かりの保存先を利用できません。\n\(reason)"
        }
        if let hintStorageFailure {
            return "再検証の手掛かりを保存できていません。\n\(hintStorageFailure)"
        }
        return nil
    }

    /// プロジェクト定義を読み込めていない状態。
    ///
    /// 読めていない一覧を土台に保存すると、既存の定義をまるごと空で上書きする。
    /// メモリに古い内容が残っていても、それがディスクの最新とは限らない。
    private var projectLoadBlockedReason: String? {
        switch projectLoadState {
        case .notLoaded:
            return "プロジェクト設定をまだ読み込んでいません。"
        case let .failed(reason):
            return "プロジェクト設定を読み込めません。"
                + "読み込めていない一覧で保存すると、既存の定義を失います。\n\(reason)"
        case .loaded:
            return nil
        }
    }

    /// 検出した既存プロセスの決着が済んでいない状態。
    private var unresolvedHandoffReason: String? {
        if handoffPresentation != nil {
            return "検出した既存プロセスの扱いが決まっていません。シートで選んでください。"
        }
        if !pendingHints.isEmpty || !pendingLegacyHints.isEmpty {
            return "決着していない既存プロセスの手掛かりが残っています。"
                + "「再検証の手掛かりを扱えません」の再試行から再検証してください。"
        }
        if !pendingManagedHints.isEmpty {
            return "状態を判定できないSupabaseの手掛かりが残っています。"
                + "画面上部の案内から再試行するか、設定が無い手掛かりを破棄してください。"
        }
        return nil
    }

    /// プロジェクト定義と起動対象を変更できない理由（プロジェクトによらない条件）。
    var configurationBlockedReason: String? {
        if isTerminating { return "アプリの終了処理を実行中です。" }
        if let activityKind { return activityKind.blockingDescription }
        if supabaseConfirmation != nil {
            return "既存のSupabaseスタックをどう扱うか決まっていません。シートで選んでください。"
        }
        if let reason = projectLoadBlockedReason { return reason }
        if let reason = unresolvedHandoffReason { return reason }
        if let reason = runtimeHintBlockReason { return reason }
        return nil
    }

    /// そのプロジェクトの定義を変更できない理由。
    ///
    /// 稼働中の変更を UI の無効化だけで防がない。API 境界で拒否しないと、
    /// ゲートが検証する設定ポートと実際に握っている実測ポートがずれる（DESIGN.md I-9）。
    /// Milestone 2 ではフィールド単位の差分を検証できないため、稼働中は全編集を拒否する。
    func configurationBlockedReason(for project: ProjectDefinition) -> String? {
        if let reason = configurationBlockedReason { return reason }
        if hasManagedResources(in: project) {
            return "「\(project.name)」には動作中のプロセスがあります。"
                + "設定値と実測がずれるため、停止してから変更してください。"
        }
        return nil
    }

    var canChangeConfiguration: Bool { configurationBlockedReason == nil }

    // MARK: - 起動・停止・切替

    /// 起動できない理由。ボタンを黙って無効化しないために使う。
    var startBlockedReason: String? {
        switch environmentState {
        case .loading:
            return "ログインシェルの環境を取得しています。"
        case let .failed(reason):
            return "ログインシェルの環境を取得できません。\n\(reason)"
        case .ready:
            break
        }
        return configurationBlockedReason
    }

    /// 起動できるが、先に別プロジェクトを停止することになる場合の注意書き。
    /// 禁止理由ではないので `startBlockedReason` と混ぜない。
    func switchNotice(for project: ProjectDefinition) -> String? {
        guard let activeProject, activeProject.id != project.id else { return nil }
        return "プロジェクト「\(activeProject.name)」は起動済みです。切り替えると、"
            + "先に「\(activeProject.name)」を停止し、ポートの解放を確認してから起動します。"
    }

    /// 起動にはログインシェル環境が要る。実行ファイルを PATH から解決するため。
    var canStart: Bool { startBlockedReason == nil }

    /// 停止できない理由。
    ///
    /// 停止は復旧手段なので、手掛かりの保存失敗を理由に禁止しない。
    /// 起動時の確認中だけは、シートの「停止する」へ導線を一本化する。
    var stopBlockedReason: String? {
        if isTerminating { return "アプリの終了処理を実行中です。" }
        if let activityKind { return activityKind.blockingDescription }
        if supabaseConfirmation != nil {
            return "既存のSupabaseスタックをどう扱うか決まっていません。シートで選んでください。"
        }
        if handoffPresentation != nil {
            return "検出した既存プロセスの扱いが決まっていません。"
                + "停止はシートの「停止する」から行ってください。"
        }
        return nil
    }

    /// 停止はプロセスグループへのシグナル送出だけで完結し、PATH を必要としない。
    /// 環境の取得に失敗している間も停止できないと、引き継いだプロセスを画面から止められなくなる。
    var canStop: Bool { stopBlockedReason == nil }

    /// 1件の操作も、保存・環境・排他条件を満たす起動済み開発環境に限定する。
    private func serviceOperationBlockedReason(
        for service: ServiceDefinition,
        in project: ProjectDefinition
    ) -> String? {
        guard self.project(project.id) == project,
              project.service(id: service.id) == service else {
            return "対象のプロセス設定が現在の登録内容と一致しません。"
        }
        guard service.kind != .supabase else {
            return "Supabaseは専用の停止・状態確認を使うため、単体の起動・再起動はできません。"
        }
        guard service.usesProcessGroupStop else {
            return RuntimeError.stopCommandUnsupported(service: service.name).description
        }
        if let reason = startBlockedReason { return reason }

        guard hasManagedResources(in: project) else {
            return "停止中の開発環境は、開発環境単位で起動してください。"
        }
        return nil
    }

    func serviceStartBlockedReason(
        for service: ServiceDefinition,
        in project: ProjectDefinition
    ) -> String? {
        if let reason = serviceOperationBlockedReason(for: service, in: project) { return reason }
        switch state(of: service.id).phase {
        case .excluded, .stopped:
            return nil
        case .starting, .stopping:
            return "プロセスの起動・停止が完了してから操作してください。"
        case .running, .healthy, .failed, .residual:
            return "動作中または失敗したプロセスには再起動を使ってください。"
        }
    }

    func canStartService(_ service: ServiceDefinition, in project: ProjectDefinition) -> Bool {
        serviceStartBlockedReason(for: service, in: project) == nil
    }

    func restartBlockedReason(
        for service: ServiceDefinition,
        in project: ProjectDefinition
    ) -> String? {
        if let reason = serviceOperationBlockedReason(for: service, in: project) { return reason }
        switch state(of: service.id).phase {
        case .running, .healthy, .failed, .residual:
            return nil
        case .starting, .stopping:
            return "プロセスの起動・停止が完了してから再起動してください。"
        case .excluded, .stopped:
            return "このプロセスは現在の起動対象として動作していません。"
        }
    }

    func canRestart(_ service: ServiceDefinition, in project: ProjectDefinition) -> Bool {
        restartBlockedReason(for: service, in: project) == nil
    }

    func restart(_ service: ServiceDefinition, in project: ProjectDefinition) {
        runServiceOperation(service, in: project, kind: .restarting)
    }

    func startService(_ service: ServiceDefinition, in project: ProjectDefinition) {
        runServiceOperation(service, in: project, kind: .starting)
    }

    private func runServiceOperation(
        _ service: ServiceDefinition,
        in project: ProjectDefinition,
        kind: ServiceOperation.Kind
    ) {
        let blockedReason = kind == .starting
            ? serviceStartBlockedReason(for: service, in: project)
            : restartBlockedReason(for: service, in: project)
        if let reason = blockedReason {
            operationError = "\(service.name) を\(kind.action)できません。\n\(reason)"
            return
        }
        guard let token = beginActivity(.operation) else {
            operationError = (activityKind?.blockingDescription ?? "ほかの処理を実行中です。")
                + "\n完了してからもう一度操作してください。"
            return
        }
        serviceOperation = ServiceOperation(
            projectID: project.id,
            serviceID: service.id,
            kind: kind
        )
        operationError = nil

        runActivity(token) { [self] in
            defer { serviceOperation = nil }

            // PIDが変わる前の完全な手掛かりを残す。保存不能なら何も停止しない。
            guard await persistRuntimeHints() else {
                operationError = "再検証の手掛かりを保存できないため、\(service.name) の\(kind.action)を中止しました。"
                    + "プロセスは停止していません。\n"
                    + (hintStorageFailure ?? "")
                return
            }

            var started = false
            do {
                switch kind {
                case .starting:
                    _ = try await coordinator.startService(
                        service, in: project, progress: progressSink(for: token), events: eventSink
                    )
                case .restarting:
                    _ = try await coordinator.restart(
                        service, in: project, progress: progressSink(for: token), events: eventSink
                    )
                }
                started = true
            } catch let failure as SwitchFailure {
                present(failure)
            } catch {
                operationError = "\(error)"
            }
            await refreshPhases()

            if await persistRuntimeHints() == false, started {
                await compensateUnsavedServiceStart(of: service, in: project, kind: kind, token: token)
            }
        }
    }

    /// 停止中のプロジェクトを起動する。稼働中の別プロジェクトがあれば切替として実行する。
    func startOrSwitch(to target: ProjectDefinition) {
        startOrSwitch(to: target, supabaseApproval: nil)
    }

    private func startOrSwitch(
        to target: ProjectDefinition,
        supabaseApproval: SupabaseApproval?
    ) {
        let source = activeProject
        guard source?.id != target.id, canStart else { return }
        guard let token = beginActivity(.operation) else { return }

        // 停止を伴う切替だけシートで出す。単純な起動は画面を遮らず、
        // 利用者が見ているプロジェクトのボタン内で進捗を示す。
        if let source {
            switchPresentation = SwitchPresentation(
                sourceID: source.id,
                sourceName: source.name,
                targetID: target.id,
                targetName: target.name
            )
        } else {
            inlineOperation = InlineOperation(projectID: target.id, kind: .starting)
        }

        runActivity(token) { [self] in
            // 成功・失敗・補償停止のどの経路を通っても、必ずインライン表示を解除する。
            defer { inlineOperation = nil }

            // 停止フェーズへ入る前に、完全なスナップショットを保存できることを確かめる。
            // ここで確かめずに進むと、切替元を停止したうえに、起動したプロセスの
            // 手掛かりも残せない状態になりうる。
            guard await persistRuntimeHints() else {
                switchPresentation = nil
                operationError = "再検証の手掛かりを保存できないため、起動を中止しました。"
                    + "プロセスは1つも起動・停止していません。\n"
                    + (hintStorageFailure ?? "")
                await refreshPhases()
                return
            }

            let previouslyManagedIDs = Set(await registry.occupyingServiceIDs(projectID: target.id))
            do {
                if let source {
                    _ = try await coordinator.switchProject(
                        from: source,
                        to: target,
                        registeredProjects: projects,
                        supabaseApproval: supabaseApproval,
                        progress: progressSink(for: token),
                        events: eventSink
                    )
                } else {
                    _ = try await coordinator.start(
                        target,
                        registeredProjects: projects,
                        supabaseApproval: supabaseApproval,
                        progress: progressSink(for: token),
                        events: eventSink
                    )
                }
                switchPresentation = nil
            } catch let failure as SwitchFailure {
                switchPresentation = nil
                if case let .supabaseConfirmationRequired(plan) = failure.reason {
                    // 承認するまで既存スタックへコマンドを送っていない。判断を求め直す。
                    supabaseConfirmation = SupabaseConfirmationPresentation(
                        projectID: target.id,
                        plan: plan
                    )
                } else {
                    present(failure)
                }
            } catch {
                switchPresentation = nil
                operationError = "\(error)"
            }
            await refreshPhases()
            // 起動したプロセスの手掛かりを残せなかったら、成功として閉じない。
            if await persistRuntimeHints() == false {
                await compensateUnsavedStart(
                    of: target, preserving: previouslyManagedIDs, token: token
                )
            }
        }
    }

    /// 確認を閉じるだけ。既存スタック、切替元、切替先のいずれも変更しない。
    func cancelSupabaseConfirmation() {
        supabaseConfirmation = nil
    }

    /// 利用者が全対象を確認したあとにだけ、承認内容を付けて起動を再試行する。
    /// 実行直前の再観測で内容が変わっていれば、Coordinatorが確認を出し直す。
    func approveSupabaseConfirmation(_ presentation: SupabaseConfirmationPresentation) {
        guard supabaseConfirmation?.id == presentation.id,
              let target = project(presentation.projectID) else { return }
        supabaseConfirmation = nil
        startOrSwitch(to: target, supabaseApproval: presentation.plan.approval)
    }

    /// 起動後に手掛かりを保存できなかったときの補償。
    ///
    /// 記録に無いプロセスを残したままクラッシュすると、次回起動時に検出も停止もできない。
    /// ポートを持たないサービスは特に回収不能になるため、今回起動した対象を停止する。
    private func compensateUnsavedStart(
        of target: ProjectDefinition,
        preserving previouslyManagedIDs: Set<UUID>,
        token: ActivityToken
    ) async {
        guard await registry.occupyingServiceIDs(projectID: target.id).isEmpty == false else {
            operationError = "再検証の手掛かりを保存できませんでした。\n"
                + (hintStorageFailure ?? "")
            return
        }

        var messages = [
            "起動したプロセスの手掛かりを保存できませんでした。",
            "「\(target.name)」で今回起動したプロセスだけを停止します。",
            hintStorageFailure ?? "",
        ].filter { !$0.isEmpty }

        // インライン表示中なら、いま何をしているのかに合わせる。
        // 停止しているのに「起動中」と出し続けない。
        if inlineOperation != nil {
            inlineOperation = InlineOperation(projectID: target.id, kind: .stopping)
        }

        var stopFailure: SwitchFailure?
        var compensationFailed = false
        do {
            try await coordinator.stopAfterUnsavedStart(
                target,
                preserving: previouslyManagedIDs,
                progress: progressSink(for: token)
            )
        } catch let failure as SwitchFailure {
            stopFailure = failure
            compensationFailed = true
            messages.append("補償のための停止に失敗しました。\n\(failure.reason.detail)")
        } catch {
            compensationFailed = true
            messages.append("補償のための停止に失敗しました。\n\(error)")
        }
        await refreshPhases()

        let hasRemainingResources = await registry.occupyingServiceIDs(projectID: target.id).isEmpty == false
        if hasRemainingResources, !compensationFailed {
            messages.append("引き継いだSupabaseと操作前から管理していたサービスは稼働を維持しています。")
        }
        if !compensationFailed {
            if await persistRuntimeHints(refreshingPorts: false) {
                messages.append("停止後の手掛かりを保存しました。")
            } else if hasRemainingResources {
                messages.append("残っているサービスの手掛かりを保存できません。保存を再試行するか、明示的に停止するまでアプリを終了しないでください。")
            } else {
                messages.append(
                    "停止後の手掛かりも保存できませんでした。起動前のスナップショットは残っています。"
                        + "古い手掛かりは次回起動時の再検証で整理されます。"
                )
            }
        } else {
            messages.append(
                "停止できなかったプロセスが残っています。手掛かりを保存できるまでアプリを終了しないでください。"
            )
        }
        operationError = messages.joined(separator: "\n")
        // 残存状態と復旧手段（確認のうえでの強制終了）を画面に出す。
        if let stopFailure { present(stopFailure) }
    }

    /// 1件の起動・再起動後の手掛かりを保存できない場合、今回起動した1件だけを停止する。
    private func compensateUnsavedServiceStart(
        of service: ServiceDefinition,
        in project: ProjectDefinition,
        kind: ServiceOperation.Kind,
        token: ActivityToken
    ) async {
        var messages = [
            "\(kind.action)した \(service.name) の手掛かりを保存できませんでした。",
            "記録に無いプロセスを残さないため、\(service.name) だけを停止します。",
            hintStorageFailure ?? "",
        ].filter { !$0.isEmpty }

        var stopFailure: SwitchFailure?
        var compensationFailed = false
        do {
            _ = try await coordinator.stopAfterUnsavedServiceStart(
                service,
                in: project,
                progress: progressSink(for: token)
            )
        } catch let failure as SwitchFailure {
            stopFailure = failure
            compensationFailed = true
            messages.append("補償のための停止に失敗しました。\n\(failure.reason.detail)")
        } catch {
            compensationFailed = true
            messages.append("補償のための停止に失敗しました。\n\(error)")
        }
        await refreshPhases()

        if !compensationFailed, await persistRuntimeHints(refreshingPorts: false) {
            messages.append("停止後の手掛かりを保存しました。")
        } else if !compensationFailed {
            messages.append("停止後の手掛かりも保存できませんでした。")
        } else {
            messages.append("停止できなかったプロセスが残っています。")
        }
        operationError = messages.joined(separator: "\n")
        if let stopFailure { present(stopFailure) }
    }

    func stopProject(_ project: ProjectDefinition) {
        guard canStop else { return }
        guard let token = beginActivity(.operation) else { return }
        // 停止だけの操作にシートは出さない。中止できる余地も無いので、
        // 「切替を中止」を持つUIを見せる意味がない。
        inlineOperation = InlineOperation(projectID: project.id, kind: .stopping)

        runActivity(token) { [self] in
            defer { inlineOperation = nil }
            do {
                _ = try await coordinator.stop(
                    project,
                    registeredProjects: projects,
                    progress: progressSink(for: token),
                    events: eventSink
                )
            } catch let failure as SwitchFailure {
                present(failure)
            } catch {
                operationError = "\(error)"
            }
            await refreshPhases()
            // 停止したプロセスを保存失敗のために再起動はしない。
            // ディスクに残る古い手掛かりは、次回の実測で安全に整理できる。
            await persistRuntimeHints()
        }
    }

    /// 通常終了で止まらなかったサービスを強制終了する。
    ///
    /// 破壊的な操作なので、呼び出し元は確認を挟んでから呼ぶこと。
    /// 一発で SIGKILL する経路にはしない（通常終了を試したあとの復旧手段）。
    func forceStop(_ details: [StopFailureDetail], in project: ProjectDefinition) {
        guard canStop else { return }
        guard let token = beginActivity(.operation) else { return }
        failurePresentation = nil

        runActivity(token) { [self] in
            do {
                let outcomes = try await coordinator.forceStop(
                    serviceIDs: details.map(\.serviceID),
                    in: project
                )
                let remaining = outcomes.compactMap { serviceID, outcome -> String? in
                    let name = project.service(id: serviceID)?.name ?? serviceID.uuidString
                    switch outcome {
                    case .stopped:
                        return nil
                    case let .residual(_, reason), let .ownershipLost(reason):
                        return "\(name): \(reason)"
                    }
                }
                if !remaining.isEmpty {
                    operationError = "強制終了しても停止できませんでした。\n"
                        + remaining.joined(separator: "\n")
                }
            } catch {
                operationError = "\(error)"
            }
            await refreshPhases()
            await persistRuntimeHints()
        }
    }

    /// 切替の中止。切替元の停止は最後まで実行し、切替先は起動しない。
    func cancelSwitch() {
        guard switchPresentation?.canCancel == true else { return }
        switchPresentation?.cancelRequested = true
        Task {
            let accepted = await coordinator.cancel()
            if !accepted {
                // 起動フェーズへ入った直後は受け付けられない。黙って無視せず理由を残す。
                switchPresentation?.cancelRequested = false
                operationError = "中止を受け付けられませんでした。"
                    + "起動フェーズに入ったか、すでに処理が完了しています。"
                    + "送出済みの停止処理は取り消せません。"
            }
        }
    }

    /// 進捗の受け口。どの操作から来た進捗かを、送り出す時点で確定させる。
    /// 受信側で「いまの操作」を推測すると、遅れて届いた古い進捗と区別できない。
    private func progressSink(for token: ActivityToken) -> SwitchCoordinator.ProgressSink {
        let continuation = eventContinuation
        let activityID = token.id
        return { state in continuation.yield(.progress(activityID: activityID, state: state)) }
    }

    /// 実行中の操作の識別子。進捗イベントの取捨に使う。
    private var currentActivityID: UInt64? { currentToken?.id }

    /// 実行中の操作に紐づいた進捗の受け口を返す。
    ///
    /// 「終わった操作の進捗が遅れて届く」状況をテストから再現するための入口で、
    /// `waitForPendingOperation()` と同じくテスト支援。UI からは呼ばない。
    func progressSinkForCurrentActivity() -> SwitchCoordinator.ProgressSink? {
        currentToken.map { progressSink(for: $0) }
    }

    private var eventSink: SwitchCoordinator.EventSink {
        let continuation = eventContinuation
        return { serviceID, event in continuation.yield(.service(serviceID, event)) }
    }

    /// 実運用と同じ直列イベント経路へ、テストから終了競合を再現するための入口。
    func serviceEventSinkForTesting() -> SwitchCoordinator.EventSink {
        eventSink
    }

    /// 実行中の操作が終わるまで待つ。テストから完了を待ち合わせるために使う。
    func waitForPendingOperation() async {
        await operationTask?.value
    }

    /// 終了直前に手掛かりを書き出す。
    ///
    /// 手掛かりの記録時刻は、プロセスグループの同定条件の上限になる。
    /// アプリが動いている間はプロセスグループを予約し続けているので、
    /// 終了の直前まで引き延ばせば、そのとき生きていた孫プロセスまで同定できる。
    /// 逆にここを省くと、最後の操作より後に生まれた孫が次回に同定できなくなる。
    ///
    /// 進行中の起動・切替と直列化する。待たずに保存すると、保存してから終了するまでの間に
    /// 起動が進み、記録に無いプロセスが残る。ポートを持たないサービスは次回検出できない。
    ///
    /// - Returns: 終了してよいか。false のときは終了を取り消すこと。
    ///   保存できないまま終了すると、残っているプロセスの手掛かりを失う。
    func flushRuntimeHintsBeforeTermination(
        waitingUpTo timeout: Duration = .seconds(30)
    ) async -> Bool {
        // 新しい処理を止めてから待つ。止めないと待ち続けることになる。
        // 起動・停止だけでなく、bootstrap と引き継ぎの照合も対象にする。
        // どちらも手掛かりを読み書きするため、待たずに保存すると取りこぼす。
        isTerminating = true

        guard await waitForActivitiesToFinish(timeout: timeout) else {
            isTerminating = false
            operationError = "起動・停止・再検証の処理が完了していないため終了できません。"
                + "処理の完了を待ってから終了してください。"
            return false
        }

        // 読み込めていない状態で保存すると、既存の記録を空の一覧で上書きする。
        guard ensureHintsLoaded() else {
            isTerminating = false
            return false
        }

        // 終了を待たせるので、時間のかかるポート実測はやり直さない。
        // ここで必要なのは錨の更新であって、ポートの最新値ではない。
        guard await persistRuntimeHints(refreshingPorts: false) else {
            // 終了要求の前の状態へ戻す。判断待ちのシートもそのまま操作を再開できる。
            isTerminating = false
            return false
        }
        return true
    }

    private func waitForActivitiesToFinish(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while currentToken != nil {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func present(_ failure: SwitchFailure) {
        // 「ログを開く」で原因サービスへ飛べるようにする。
        var logTarget: SidebarItem?
        if case let .startFailed(serviceName, _) = failure.reason,
           let projectID = failure.facts.target?.projectID,
           let project = project(projectID),
           let service = project.services.first(where: { $0.name == serviceName }) {
            logTarget = .service(projectID: projectID, serviceID: service.id)
        }
        failurePresentation = FailurePresentation(failure: failure, logTarget: logTarget)
    }

    func openLogTarget(_ item: SidebarItem) {
        expandedProjectIDs.insert(item.projectID)
        selection = item
        if case let .service(_, serviceID) = item {
            markLogAsRead(serviceID: serviceID)
            if runtimeIncident?.serviceID == serviceID {
                runtimeIncident = nil
            }
        }
    }

    func dismissRuntimeIncident() {
        runtimeIncident = nil
    }

    // MARK: - 状態の反映

    /// 実測から画面表示を組み立て直す。
    ///
    /// 読み取り専用なので排他の対象にしない。ここまで止めると、進行中の起動の
    /// 進捗が画面へ反映されなくなる。
    ///
    /// 引き継いだサービスは起動イベントを出さないため、状態だけを同期すると
    /// 稼働中なのに PID もポートも空欄のままになる。`ObservedRuntime` まで反映する。
    private func refreshPhases() async {
        var managedProjectIDs = Set<UUID>()
        var displayedSupabaseIDs = Set<SupabaseProjectID>()
        for project in projects {
            let fact = await coordinator.projectFact(project)
            projectPhases[project.id] = fact.phase
            let occupyingServiceIDs = await registry.occupyingServiceIDs(projectID: project.id)
            if !occupyingServiceIDs.isEmpty {
                managedProjectIDs.insert(project.id)
            }
            for serviceFact in fact.services {
                // `ObservedRuntime` は本体の同一性を前提にしており、再起動後に登録した
                // 残存グループでは作れない。表示できる情報を落とさないよう snapshot を使う。
                let snapshot = await registry.runtimeSnapshot(serviceID: serviceFact.serviceID)
                guard let service = project.service(id: serviceFact.serviceID) else {
                    preconditionFailure("観測結果に登録のないサービスが含まれています。")
                }
                let supabase = await supabaseUIState(for: service)
                if let projectID = supabase?.projectID { displayedSupabaseIDs.insert(projectID) }
                update(serviceFact.serviceID) { current in
                    current.phase = serviceFact.phase
                    current.supabase = supabase
                    guard serviceFact.phase.isActive else {
                        current.observedPortRecord = .observed([])
                        current.observedPorts = []
                        current.startedAt = nil
                        current.processID = nil
                        current.processGroupID = nil
                        return
                    }
                    guard let snapshot else { return }
                    // 孫が残ってポートを握っている場合も、実測値をそのまま出す。
                    current.observedPortRecord = snapshot.observedPortRecord
                    current.observedPorts = snapshot.observedPorts
                    let portWarning = "listen ポートを取得できません。取得できるまで「ポートなし」とは判断しません。"
                    let isManaged = project.service(id: serviceFact.serviceID)?.kind == .supabase
                    if snapshot.observedPortRecord == .unavailable, !isManaged {
                        current.warning = portWarning
                    } else if current.warning == portWarning {
                        current.warning = nil
                    }
                    current.processGroupID = snapshot.processGroupID
                    current.startedAt = snapshot.startedAt
                    // 本体が終了している間は PID を出さない。停止済みの PID を
                    // 動いているかのように見せない。
                    current.processID = current.phase == .residual ? nil : snapshot.processID
                }
            }
        }
        // まとめて置き換え、定義から消えたプロジェクトIDも残さない。
        projectIDsWithManagedResources = managedProjectIDs
        let supabaseSnapshot = await registry.latestSupabaseSnapshot()
        supabaseObservationError = supabaseSnapshot?.inventoryFailure
        unregisteredSupabaseObservations = supabaseSnapshot?.observations.filter {
            !displayedSupabaseIDs.contains($0.projectID)
        } ?? []
    }

    private func supabaseUIState(for service: ServiceDefinition) async -> SupabaseUIState? {
        guard service.kind == .supabase else { return nil }
        if let observed = await registry.managedObservation(serviceID: service.id) {
            return SupabaseUIState(
                projectID: observed.projectID, state: observed.state,
                relationship: await registry.managedRelationship(serviceID: service.id),
                detail: observed.detail
            )
        }
        let projectID: SupabaseProjectID
        do {
            guard let configuration = service.supabaseConfiguration else {
                throw RuntimeError.managedCommandInvalid(
                    service: service.name, reason: service.supabaseConfigurationFailureReason
                )
            }
            projectID = try configuration.resolveProjectID()
        } catch {
            return SupabaseUIState(projectID: nil, state: .unknown, relationship: nil, detail: "\(error)")
        }
        guard let snapshot = await registry.latestSupabaseSnapshot() else {
            return SupabaseUIState(
                projectID: projectID, state: .unknown, relationship: nil,
                detail: "Supabaseの状態をまだ観測できていません。"
            )
        }
        let observation = snapshot.observation(of: projectID)
        return SupabaseUIState(
            projectID: projectID, state: observation.state, relationship: nil, detail: observation.detail
        )
    }

    /// 次回起動時の再検証に使う手掛かりを書き出す。稼働状態の保存ではない。
    /// - Returns: 書き出せたか。失敗を握りつぶすと、残っているプロセスの手掛かりを失う。
    @discardableResult
    private func persistRuntimeHints(refreshingPorts: Bool = true) async -> Bool {
        // 読み込む前に保存しない。既存の記録を空の一覧で消してしまう。
        // 保存先が無い場合もここで false になる。
        guard ensureHintsLoaded(), case .available = hintStorage else {
            return false
        }

        // 期待するポートは次回の照合材料になるので、書き出す直前に実測し直す。
        // 失敗しても握りつぶしにはならない。実測できなかったサービスの記録は
        // `.unavailable` になり、次回は「ポートを持たないサービス」と区別されて
        // 引き継ぎ対象から外れる（停止対象としては残る）。
        // 本体が終了して孫だけ残っている場合も対象にする。ポートを握るのは孫だから。
        if refreshingPorts {
            var failures: [String] = []
            for project in projects {
                for serviceID in await registry.occupyingServiceIDs(projectID: project.id) {
                    do {
                        try await registry.refreshPorts(serviceID: serviceID)
                    } catch {
                        let serviceName = project.service(id: serviceID)?.name ?? serviceID.uuidString
                        failures.append("\(serviceName): \(error)")
                    }
                }
            }
            hintPortWarning = failures.isEmpty
                ? nil
                : "listen ポートを更新できないサービスがあります。\n"
                    + failures.joined(separator: "\n")
            refreshHintError()
        }

        return await saveCompleteHintSnapshot(
            pendingHints: pendingHints,
            pendingLegacyHints: pendingLegacyHints
        )
    }

    /// Registry管理下の全サービスと未決着hintを1つの完全なスナップショットとして保存する。
    /// Registry側で1件でも最新値を作れなければ、既存ファイルには一切触れない。
    private func saveCompleteHintSnapshot(
        pendingHints: [UUID: RuntimeHint],
        pendingLegacyHints: [UUID: LegacyRuntimeHint],
        pendingManagedHints: [UUID: ManagedRuntimeHint]? = nil
    ) async -> Bool {
        guard case let .available(hintStore) = hintStorage else { return false }
        do {
            // 管理下にあるものを優先する。保存直前に錨を測り直した新しい値のため。
            var merged = pendingHints
            for hint in try await registry.runtimeHints() {
                merged[hint.serviceID] = hint
            }
            let hints = merged.values.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }
            // 安全な錨へ変換できていない旧形式も、変換できるまで捨てない。
            let legacy = pendingLegacyHints.values
                .filter { merged[$0.serviceID] == nil }
                .sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }

            var managed = pendingManagedHints ?? self.pendingManagedHints
            for hint in try await registry.managedRuntimeHints() {
                managed[hint.serviceID] = hint
            }
            let managedHints = managed.values.sorted {
                $0.serviceID.uuidString < $1.serviceID.uuidString
            }

            try hintStore.save(hints, legacy: legacy, managed: managedHints)
            hintStorageFailure = nil
            refreshHintError()
            return true
        } catch {
            hintStorageFailure = "\(error)"
            refreshHintError()
            return false
        }
    }

    /// イベントの付随情報を反映する。終了後のphaseはrefreshPhasesの実測結果を正とする。
    func apply(_ event: ServiceSupervisor.Event, to serviceID: UUID) {
        switch event {
        case .logSessionStarted:
            // 停止中は直前の原因を読めるよう残し、次の起動試行で新しいログだけにする。
            logBuffer(of: serviceID).clear()
            update(serviceID) {
                $0.lastMessage = nil
                $0.warning = nil
            }
        case let .started(runtime):
            update(serviceID) {
                // 初期観測が終わっていないので「起動中」。起動済みにはしない。
                $0.phase = .running
                $0.observedPortRecord = .unavailable
                $0.startedAt = runtime.startedAt
                $0.processID = runtime.identity.pid
                $0.processGroupID = runtime.processGroupID
                $0.observedPorts = runtime.observedPorts
                $0.warning = nil
            }
        case let .log(lines):
            let buffer = logBuffer(of: serviceID)
            buffer.append(lines)
            if case let .service(_, selectedServiceID) = selection,
               selectedServiceID == serviceID {
                buffer.markStderrAsRead()
            }
        case let .ports(ports):
            update(serviceID) {
                $0.observedPortRecord = .observed(ports.map(\.port))
                $0.observedPorts = ports
            }
        case let .warning(message):
            update(serviceID) { $0.warning = message }
        case let .exited(status, requestedByUser, startupConfirmed):
            update(serviceID) { current in
                // 本体は終了したが、孫がポートを握ったままのことがある。
                // ここで実測ポートを消すと「残存あり」なのに listen なしと表示される。
                // ポートの去就は直後の refreshPhases が実測から決める。
                current.startedAt = nil
                current.processID = nil
                current.lastMessage = status.description
                // 遅れて届いた終了通知で、補償停止後の「対象外」や残存状態を上書きしない。
                // phaseはイベント処理直後のrefreshPhasesでCoordinatorから取得する。
            }
            if !requestedByUser, startupConfirmed,
               let project = projects.first(where: { $0.service(id: serviceID) != nil }),
               let service = project.service(id: serviceID) {
                runtimeIncident = RuntimeIncident(
                    projectID: project.id,
                    serviceID: serviceID,
                    serviceName: service.name,
                    status: status.description
                )
            }
        }
    }

    private func update(_ serviceID: UUID, _ transform: (inout ServiceUIState) -> Void) {
        var current = serviceStates[serviceID] ?? ServiceUIState()
        transform(&current)
        serviceStates[serviceID] = current
    }

    // MARK: - 開く

    /// ブラウザで開く。`openUrl`を持つポートだけがメニューに載る。
    func open(_ port: PortSpec) {
        guard let openURL = port.openURL, let url = URL(string: openURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ workingDirectory: WorkingDirectoryDefinition) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory.directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            operationError = "作業ディレクトリ「\(workingDirectory.name)」を利用できません"
                + "（\(workingDirectory.directory.path)）。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([workingDirectory.directory])
    }
}
