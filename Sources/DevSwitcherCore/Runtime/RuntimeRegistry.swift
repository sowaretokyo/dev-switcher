import Darwin
import Foundation

/// actorは`await`をまたいだ再入を防がないため、起動・停止の排他は明示的なフラグで守る。
/// プロジェクト間の排他をUIだけに依存させないため、この層でも実プロセスから判定する。
public actor RuntimeRegistry {
    private struct ServiceOwner {
        let projectID: UUID
        let projectName: String
    }

    private var supervisors: [UUID: ServiceSupervisor] = [:]
    private var owners: [UUID: ServiceOwner] = [:]
    private var operationInFlight = false
    private var cachedEnvironment: ShellEnvironment?
    private let portPollInterval: Duration
    private let logDirectoryOverride: URL?
    private let environmentLoader: ShellEnvironmentLoader

    /// テストごとにログインシェルを起動しないよう、取得処理を差し替え可能にする。
    public typealias ShellEnvironmentLoader = @Sendable () async throws -> ShellEnvironment

    public init(
        portPollInterval: Duration = .seconds(2),
        logDirectory: URL? = nil,
        environmentLoader: @escaping ShellEnvironmentLoader = { try await LoginShellEnvironment.load() }
    ) {
        self.portPollInterval = portPollInterval
        self.logDirectoryOverride = logDirectory
        self.environmentLoader = environmentLoader
    }

    /// 取得失敗時に意図しない実行ファイルを選ばないよう、最小PATHへフォールバックしない。
    @discardableResult
    public func environment(reload: Bool = false) async throws -> ShellEnvironment {
        if !reload, let cachedEnvironment {
            return cachedEnvironment
        }
        let loaded = try await environmentLoader()
        cachedEnvironment = loaded
        return loaded
    }

    public func start(
        service: ServiceDefinition,
        in project: ProjectDefinition
    ) async throws -> AsyncStream<ServiceSupervisor.Event> {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        if let existing = supervisors[service.id] {
            if await existing.isRunning {
                throw RuntimeError.alreadyRunning(service: service.name)
            }
            // 親が終了していても孫が残っていることがある。ここで supervisor を
            // 差し替えると、残ったプロセスグループへの停止手段を失う。
            if await existing.isOccupyingResources(),
               let processGroupID = await existing.processGroupID {
                throw RuntimeError.residualProcessesRemain(
                    service: service.name,
                    processGroupID: processGroupID
                )
            }
        }

        // 保存状態は古くなりうるため、プロジェクト間の排他は実プロセスから判断する。
        if let running = await runningProject(), running.projectID != project.id {
            throw RuntimeError.otherProjectRunning(
                running: running.projectName,
                requested: project.name
            )
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: project.directory.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw RuntimeError.projectDirectoryMissing(project.directory)
        }

        let environment = try await environment()
        let resolved = try ExecutableResolver.resolve(
            service.start,
            searchPath: environment.searchPath
        )

        let supervisor = ServiceSupervisor(
            serviceID: service.id,
            serviceName: service.name,
            command: resolved,
            logDirectory: try logDirectoryOverride ?? ApplicationPaths.logDirectory(),
            portPollInterval: portPollInterval
        )
        supervisors[service.id] = supervisor
        owners[service.id] = ServiceOwner(projectID: project.id, projectName: project.name)
        return try await supervisor.start(environment: environment.variables)
    }

    public func stop(
        service: ServiceDefinition,
        grace: Duration = .seconds(10)
    ) async throws -> ServiceSupervisor.StopOutcome {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard let supervisor = supervisors[service.id] else {
            throw RuntimeError.notRunning(service: service.name)
        }
        return try await supervisor.stop(grace: grace)
    }

    /// 強制終了。利用者が対象を確認して明示的に選んだ場合にのみ呼ぶ。
    public func forceStop(
        service: ServiceDefinition,
        grace: Duration = .seconds(5)
    ) async throws -> ServiceSupervisor.StopOutcome {
        guard !operationInFlight else { throw RuntimeError.operationInProgress }
        operationInFlight = true
        defer { operationInFlight = false }

        guard let supervisor = supervisors[service.id] else {
            throw RuntimeError.notRunning(service: service.name)
        }
        return try await supervisor.forceStop(grace: grace)
    }

    public func observedRuntime(serviceID: UUID) async -> ObservedRuntime? {
        guard let supervisor = supervisors[serviceID] else { return nil }
        return await supervisor.observedRuntime
    }

    public func runningServiceIDs() async -> Set<UUID> {
        var running: Set<UUID> = []
        for (id, supervisor) in supervisors {
            if await supervisor.isRunning {
                running.insert(id)
            }
        }
        return running
    }

    public func runningProjectID() async -> UUID? {
        await runningProject()?.projectID
    }

    public func occupiedProcessGroup(serviceID: UUID) async -> pid_t? {
        guard let supervisor = supervisors[serviceID],
              await supervisor.isOccupyingResources()
        else { return nil }
        return await supervisor.processGroupID
    }

    private func runningProject() async -> ServiceOwner? {
        for (serviceID, supervisor) in supervisors {
            guard await supervisor.isOccupyingResources(), let owner = owners[serviceID] else {
                continue
            }
            return owner
        }
        return nil
    }
}
