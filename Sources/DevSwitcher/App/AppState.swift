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

    var description: String {
        switch self {
        case let .storeUnavailable(reason):
            "設定の保存先を利用できません。\n\(reason)"
        case let .projectNotFound(id):
            "編集対象のプロジェクトが見つかりません（\(id.uuidString)）。"
        }
    }
}

/// 古いPIDやポートを信用しないよう、稼働状態は保存せず`RuntimeRegistry`の観測結果だけを反映する。
@MainActor
@Observable
final class AppState {
    enum EnvironmentState: Equatable {
        case loading
        case ready(searchPathCount: Int)
        case failed(String)
    }

    struct ServiceUIState: Equatable {
        var phase: ServicePhase = .stopped
        var observedPorts: [ObservedPort] = []
        var startedAt: Date?
        var warning: String?
        var lastMessage: String?
        var processID: pid_t?
        var processGroupID: pid_t?
    }

    struct ResidualPrompt: Identifiable, Equatable {
        /// 残存が判明した経緯。文言を実際に起きたことへ合わせるために持つ。
        enum Cause: Equatable {
            case stopTimedOut
            case exitedWithSurvivors
            case launchCancelled
        }

        let id = UUID()
        let projectID: UUID
        let serviceID: UUID
        let serviceName: String
        let processGroupID: pid_t
        let cause: Cause
    }

    struct ProjectFormPresentation: Identifiable {
        let id = UUID()
        let project: ProjectDefinition?
    }

    private(set) var projects: [ProjectDefinition] = []
    private(set) var serviceStates: [UUID: ServiceUIState] = [:]
    private(set) var logBuffers: [UUID: LogBuffer] = [:]
    private(set) var busyServiceIDs: Set<UUID> = []
    private(set) var environmentState: EnvironmentState = .loading
    private(set) var storeError: String?

    var selection: SidebarItem?
    var expandedProjectIDs: Set<UUID> = []
    var projectFormPresentation: ProjectFormPresentation?
    var operationError: String?
    var residualPrompt: ResidualPrompt?

    private let registry = RuntimeRegistry()
    private var store: ProjectStore?

    init() {
        do {
            store = try ProjectStore.defaultStore()
        } catch {
            storeError = "\(error)"
        }
    }

    var storeLocation: String {
        store?.fileURL.path ?? "未設定"
    }

    var canStartServices: Bool {
        if case .ready = environmentState { return true }
        return false
    }

    var activeProject: ProjectDefinition? {
        projects.first { project in
            project.services.contains { state(of: $0.id).phase.isActive }
        }
    }

    /// UIの無効化は案内にすぎないため、実際の排他は`RuntimeRegistry`にも委ねる。
    func canStart(_ service: ServiceDefinition, in project: ProjectDefinition) -> Bool {
        guard canStartServices, !isBusy(service.id) else { return false }
        guard let activeProject else { return true }
        return activeProject.id == project.id
    }

    /// 起動できない理由。ボタンを黙って無効化しないために使う。
    /// ログインシェル環境の問題は画面上部のバナーが出すので、ここでは重ねて出さない。
    func startBlockedReason(for project: ProjectDefinition) -> String? {
        guard let activeProject, activeProject.id != project.id else { return nil }
        return "プロジェクト「\(activeProject.name)」が稼働中です。同時に稼働できるプロジェクトは1つだけのため、先に停止してください。"
    }

    // MARK: - 起動時

    func bootstrap() async {
        loadProjects()
        await loadEnvironment()
    }

    func loadProjects() {
        guard let store else { return }
        do {
            projects = try store.load()
            storeError = nil
            if selection == nil, let first = projects.first {
                selection = .project(first.id)
                expandedProjectIDs.insert(first.id)
            }
        } catch {
            storeError = "\(error)"
        }
    }

    func loadEnvironment() async {
        environmentState = .loading
        do {
            let environment = try await registry.environment(reload: true)
            environmentState = .ready(searchPathCount: environment.searchPath.count)
        } catch {
            environmentState = .failed("\(error)")
        }
    }

    // MARK: - プロジェクト

    func project(_ id: UUID) -> ProjectDefinition? {
        projects.first { $0.id == id }
    }

    func addProject(_ project: ProjectDefinition) throws {
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        try store.save(projects + [project])
        projects.append(project)
        expandedProjectIDs.insert(project.id)
        selection = .project(project.id)
    }

    func updateProject(_ project: ProjectDefinition) throws {
        guard let store else {
            throw AppError.storeUnavailable(storeError ?? "保存先が初期化されていません。")
        }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw AppError.projectNotFound(project.id)
        }

        var updatedProjects = projects
        updatedProjects[index] = project
        try store.save(updatedProjects)
        projects = updatedProjects
        selection = .project(project.id)
        expandedProjectIDs.insert(project.id)
    }

    func presentProjectForm(editing project: ProjectDefinition? = nil) {
        projectFormPresentation = ProjectFormPresentation(project: project)
    }

    func canEdit(_ project: ProjectDefinition) -> Bool {
        !project.services.contains { service in
            state(of: service.id).phase.isActive || isBusy(service.id)
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

    func isBusy(_ serviceID: UUID) -> Bool {
        busyServiceIDs.contains(serviceID)
    }

    func phase(of project: ProjectDefinition) -> ServicePhase {
        let phases = project.services.map { state(of: $0.id).phase }
        if phases.contains(where: { if case .residual = $0 { return true } else { return false } }) {
            return .residual
        }
        if phases.contains(.stopping) { return .stopping }
        if phases.contains(.starting) { return .starting }
        if phases.contains(.running) { return .running }
        if let failure = phases.first(where: { if case .failed = $0 { return true } else { return false } }) {
            return failure
        }
        return .stopped
    }

    // MARK: - 起動と停止

    func start(service: ServiceDefinition, in project: ProjectDefinition) {
        guard !busyServiceIDs.contains(service.id) else { return }
        busyServiceIDs.insert(service.id)
        update(service.id) {
            $0.phase = .starting
            $0.warning = nil
            $0.lastMessage = nil
            $0.observedPorts = []
        }
        logBuffer(of: service.id).clear()

        Task {
            do {
                let stream = try await registry.start(service: service, in: project)
                busyServiceIDs.remove(service.id)
                for await event in stream {
                    handle(event, for: service, in: project)
                }
            } catch {
                busyServiceIDs.remove(service.id)
                update(service.id) { $0.phase = .failed(reason: "\(error)") }
                // 起動取消後の残存をエラー表示だけで終わらせず、停止手段を出す。
                let hasResidual = await presentResidualIfNeeded(
                    for: service,
                    in: project,
                    cause: .launchCancelled
                )
                if !hasResidual {
                    operationError = "\(error)"
                }
            }
        }
    }

    func stop(service: ServiceDefinition, in project: ProjectDefinition) {
        guard !busyServiceIDs.contains(service.id) else { return }
        let previousPhase = state(of: service.id).phase
        // 既に終了しているサービスへ停止操作をかけない。
        // かけると、停止操作なしに終了した失敗を「停止中」で塗りつぶしてしまう。
        guard previousPhase.isActive else { return }
        busyServiceIDs.insert(service.id)
        update(service.id) { $0.phase = .stopping }

        Task {
            do {
                let outcome = try await registry.stop(service: service)
                busyServiceIDs.remove(service.id)
                switch outcome {
                case let .exited(status):
                    update(service.id) {
                        $0.phase = .stopped
                        $0.observedPorts = []
                        $0.startedAt = nil
                        $0.lastMessage = status.description
                    }
                case let .residual(processGroupID):
                    update(service.id) { $0.phase = .residual }
                    residualPrompt = ResidualPrompt(
                        projectID: project.id,
                        serviceID: service.id,
                        serviceName: service.name,
                        processGroupID: processGroupID,
                        cause: .stopTimedOut
                    )
                }
            } catch {
                busyServiceIDs.remove(service.id)
                // 停止操作の前にプロセスが消えていることがある（残存していた孫の自然終了など）。
                // その場合はエラーではなく、実測どおり停止済みとして扱う。
                if await registry.occupiedProcessGroup(serviceID: service.id) == nil {
                    update(service.id) {
                        $0.phase = .stopped
                        $0.observedPorts = []
                        $0.startedAt = nil
                        $0.lastMessage = "プロセスは既に終了しています。"
                    }
                } else {
                    // 停止できなかったので状態は元へ戻す。止まったことにしない。
                    update(service.id) { $0.phase = previousPhase }
                    operationError = "\(error)"
                }
            }
        }
    }

    /// 強制終了。利用者が確認シートで明示的に選んだときだけ呼ぶ。
    func forceStop(service: ServiceDefinition) {
        guard !busyServiceIDs.contains(service.id) else { return }
        busyServiceIDs.insert(service.id)

        Task {
            do {
                let outcome = try await registry.forceStop(service: service)
                busyServiceIDs.remove(service.id)
                switch outcome {
                case let .exited(status):
                    update(service.id) {
                        $0.phase = .stopped
                        $0.observedPorts = []
                        $0.startedAt = nil
                        $0.lastMessage = "強制終了しました（\(status.description)）"
                    }
                case .residual:
                    update(service.id) {
                        $0.phase = .residual
                        $0.lastMessage = "強制終了後もプロセスが残っています。"
                    }
                }
            } catch {
                busyServiceIDs.remove(service.id)
                if await registry.occupiedProcessGroup(serviceID: service.id) == nil {
                    update(service.id) {
                        $0.phase = .stopped
                        $0.observedPorts = []
                        $0.startedAt = nil
                        $0.lastMessage = "プロセスは既に終了しています。"
                    }
                } else {
                    operationError = "\(error)"
                }
            }
        }
    }

    private func handle(
        _ event: ServiceSupervisor.Event,
        for service: ServiceDefinition,
        in project: ProjectDefinition
    ) {
        let serviceID = service.id
        switch event {
        case let .started(runtime):
            update(serviceID) {
                $0.phase = .running
                $0.startedAt = runtime.startedAt
                $0.processID = runtime.identity.pid
                $0.processGroupID = runtime.processGroupID
                $0.observedPorts = runtime.observedPorts
            }
        case let .log(lines):
            logBuffer(of: serviceID).append(lines)
        case let .ports(ports):
            update(serviceID) { $0.observedPorts = ports }
        case let .warning(message):
            update(serviceID) { $0.warning = message }
        case let .exited(status, requestedByUser):
            update(serviceID) { current in
                current.observedPorts = []
                current.startedAt = nil
                current.processID = nil
                // 終了コード0でも、停止要求なしの終了はサービスの成功とみなさない。
                if requestedByUser {
                    current.phase = .stopped
                    current.lastMessage = status.description
                } else {
                    current.phase = .failed(
                        reason: "停止操作なしに終了しました（\(status.description)）"
                    )
                }
            }
            if !requestedByUser {
                // 親だけが終了した場合も、残った孫の停止手段を失敗表示に隠さない。
                Task {
                    await presentResidualIfNeeded(
                        for: service,
                        in: project,
                        cause: .exitedWithSurvivors
                    )
                }
            }
        }
    }

    @discardableResult
    private func presentResidualIfNeeded(
        for service: ServiceDefinition,
        in project: ProjectDefinition,
        cause: ResidualPrompt.Cause
    ) async -> Bool {
        guard let processGroupID = await registry.occupiedProcessGroup(serviceID: service.id)
        else { return false }

        update(service.id) {
            $0.phase = .residual
            $0.lastMessage = "プロセスグループ \(processGroupID) にプロセスが残っています。"
        }
        residualPrompt = ResidualPrompt(
            projectID: project.id,
            serviceID: service.id,
            serviceName: service.name,
            processGroupID: processGroupID,
            cause: cause
        )
        return true
    }

    private func update(_ serviceID: UUID, _ transform: (inout ServiceUIState) -> Void) {
        var current = serviceStates[serviceID] ?? ServiceUIState()
        transform(&current)
        serviceStates[serviceID] = current
    }
}
