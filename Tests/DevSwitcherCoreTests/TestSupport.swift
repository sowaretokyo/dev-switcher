import Foundation
@testable import DevSwitcherCore

/// 実際の `zsh -lic` を確認するテストは `LoginShellEnvironmentTests` の1件だけにしている。
/// 各テストがログインシェルを起動すると、利用者の zsh 設定次第で並列実行が不安定になるため。
let fixedShellEnvironment = try! ShellEnvironment(
    variables: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
)

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("devswitcher-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeService(
    name: String = "Web",
    kind: ServiceKind = .web,
    ports: [PortSpec] = [PortSpec(port: 3000, isPrimary: true)],
    executable: String = "/bin/echo",
    arguments: [String] = ["hello"],
    workingDirectory: URL,
    stop: CommandSpec? = nil,
    enabledByDefault: Bool = true,
    failurePolicy: FailurePolicy = .block
) -> LaunchUnit {
    LaunchUnit(
        name: name,
        kind: kind,
        ports: ports,
        start: CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        ),
        stop: stop,
        enabledByDefault: enabledByDefault,
        failurePolicy: failurePolicy
    )
}

func makeProject(
    name: String = "Demo",
    directory: URL,
    services: [LaunchUnit]? = nil,
    stopOrder: [UUID]? = nil,
    enabledNow: [UUID: Bool] = [:]
) -> ProjectDefinition {
    ProjectDefinition(
        name: name,
        color: .blue,
        directory: directory,
        services: services ?? [makeService(workingDirectory: directory)],
        stopOrder: stopOrder,
        enabledNow: enabledNow
    )
}

/// 起動順・終了順を実プロセスから確かめるためのサービス。
///
/// 起動時に名前を`startLog`へ、SIGTERM 受信時に`stopLog`へ追記して生き続ける。
/// 利用者入力ではなく、テストが組み立てる固定コマンド。
func makeOrderedService(
    name: String,
    kind: ServiceKind = .worker,
    ports: [PortSpec] = [],
    workingDirectory: URL,
    startLog: URL,
    stopLog: URL,
    failurePolicy: FailurePolicy = .block,
    enabledByDefault: Bool = true
) -> LaunchUnit {
    let script = """
        trap 'echo \(name) >> "\(stopLog.path)"; exit 0' TERM
        echo \(name) >> "\(startLog.path)"
        while true; do sleep 0.1; done
        """
    return makeService(
        name: name,
        kind: kind,
        ports: ports,
        executable: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: workingDirectory,
        enabledByDefault: enabledByDefault,
        failurePolicy: failurePolicy
    )
}

/// 起動直後に異常終了するサービス。
/// ポートを取れずに終了した開発サーバーと同じ結末を、実プロセスで再現するために使う。
func makeFailingService(
    name: String,
    kind: ServiceKind = .worker,
    ports: [PortSpec] = [],
    workingDirectory: URL,
    failurePolicy: FailurePolicy,
    exitCode: Int32 = 3
) -> LaunchUnit {
    makeService(
        name: name,
        kind: kind,
        ports: ports,
        executable: "/bin/sh",
        arguments: ["-c", "exit \(exitCode)"],
        workingDirectory: workingDirectory,
        failurePolicy: failurePolicy
    )
}

/// Docker inventoryとSupabase CLIの両方を差し替えるテスト用の世界。
///
/// 実Dockerにも利用者のSupabaseにも触れず、状態遷移と実行コマンドだけを検証する。
/// `start`と`stop`はこの世界の状態を変えるので、CLIの契約どおりの順序も確かめられる。
actor FakeSupabaseWorld: SupabaseInventoryProbing, ManagedStackCommandRunning {
    struct CommandRecord: Equatable, Sendable {
        let executable: String
        let arguments: [String]

        var line: String { ([executable] + arguments).joined(separator: " ") }
    }

    enum CommandFailure: Equatable, Sendable {
        /// 終了コードだけ失敗する。
        case exit(code: Int32)
        /// 実行そのものができない（実行ファイルを解決できないなど）。
        case unavailable(String)
    }

    private var stacks: [SupabaseProjectID: SupabaseContainerObservation]
    private var inventoryFailure: String?
    private var startFailure: CommandFailure?
    private var stopFailure: CommandFailure?
    private var statusFailure: CommandFailure?
    /// `start`呼び出しと同時に外部スタックが現れる競合を再現する。
    private var stackAppearingOnStart: (SupabaseProjectID, SupabaseContainerObservation)?
    /// `stop`が終了コード0を返してもコンテナを残す。停止確認の検証に使う。
    private var stopLeavesStackRunning = false
    private(set) var commands: [CommandRecord] = []
    /// `run`に渡された実行境界の規則。`commands`と同じ順で記録する。
    private(set) var policies: [ManagedStackCommandPolicy] = []

    init(stacks: [String: SupabaseContainerObservation] = [:]) {
        var initial: [SupabaseProjectID: SupabaseContainerObservation] = [:]
        for (rawValue, observation) in stacks {
            guard let projectID = SupabaseProjectID(rawValue: rawValue) else {
                preconditionFailure("テスト用の project_id が不正です: \(rawValue)")
            }
            initial[projectID] = observation
        }
        self.stacks = initial
    }

    // MARK: - 世界の操作

    func setStack(_ rawValue: String, _ observation: SupabaseContainerObservation?) {
        guard let projectID = SupabaseProjectID(rawValue: rawValue) else {
            preconditionFailure("テスト用の project_id が不正です: \(rawValue)")
        }
        stacks[projectID] = observation
    }

    func failInventory(_ reason: String?) { inventoryFailure = reason }
    func failStart(_ failure: CommandFailure?) { startFailure = failure }
    func failStop(_ failure: CommandFailure?) { stopFailure = failure }
    func failStatus(_ failure: CommandFailure?) { statusFailure = failure }
    func makeStackAppearWhenStartRuns(
        _ rawValue: String,
        observation: SupabaseContainerObservation
    ) {
        guard let projectID = SupabaseProjectID(rawValue: rawValue) else {
            preconditionFailure("テスト用の project_id が不正です: \(rawValue)")
        }
        stackAppearingOnStart = (projectID, observation)
    }
    func keepStackAfterStop(_ keep: Bool) { stopLeavesStackRunning = keep }
    func resetCommands() {
        commands.removeAll()
        policies.removeAll()
    }

    var commandLines: [String] { commands.map(\.line) }

    var runningProjectIDs: [String] {
        stacks.keys.map(\.rawValue).sorted()
    }

    // MARK: - SupabaseInventoryProbing

    func containers() async -> SupabaseInventoryResult {
        if let inventoryFailure { return .unobservable(reason: inventoryFailure) }
        return .observed(stacks)
    }

    // MARK: - ManagedStackCommandRunning

    func run(
        _ command: CommandSpec,
        policy: ManagedStackCommandPolicy
    ) async throws -> ManagedStackCommandResult {
        commands.append(
            CommandRecord(executable: command.executable, arguments: command.arguments)
        )
        policies.append(policy)
        // 生成側が変わっても、危険なオプションが実行境界へ届かないことを確かめる。
        for forbidden in ["--all", "--no-backup"] where command.arguments.contains(forbidden) {
            throw ManagedStackCommandError.forbiddenOption(
                command: command.displayCommandLine,
                option: forbidden
            )
        }

        if command.arguments.contains("start") {
            return try runStart(command)
        }
        if command.arguments.contains("stop") {
            return try runStop(command)
        }
        if command.arguments.contains("status") {
            return try runStatus(command)
        }
        return ManagedStackCommandResult(
            status: .exited(code: 64),
            standardOutput: "",
            standardError: "unexpected command"
        )
    }

    private func runStart(_ command: CommandSpec) throws -> ManagedStackCommandResult {
        if let appearing = stackAppearingOnStart {
            stacks[appearing.0] = appearing.1
            stackAppearingOnStart = nil
        }
        if let failure = startFailure { return try result(for: failure, command: command) }
        guard let projectID = try? projectID(for: command) else {
            return ManagedStackCommandResult(
                status: .exited(code: 1),
                standardOutput: "",
                standardError: "config.toml を読めません"
            )
        }
        stacks[projectID] = .databaseHealthy
        return ManagedStackCommandResult(
            status: .exited(code: 0),
            standardOutput: "Started supabase local development setup.",
            standardError: ""
        )
    }

    private func runStop(_ command: CommandSpec) throws -> ManagedStackCommandResult {
        if let failure = stopFailure { return try result(for: failure, command: command) }
        guard let index = command.arguments.firstIndex(of: "--project-id"),
              command.arguments.indices.contains(index + 1),
              let projectID = SupabaseProjectID(rawValue: command.arguments[index + 1]) else {
            return ManagedStackCommandResult(
                status: .exited(code: 2),
                standardOutput: "",
                standardError: "--project-id が指定されていません"
            )
        }
        if !stopLeavesStackRunning {
            stacks[projectID] = nil
        }
        return ManagedStackCommandResult(
            status: .exited(code: 0),
            standardOutput: "Stopped supabase local development setup.",
            standardError: ""
        )
    }

    private func runStatus(_ command: CommandSpec) throws -> ManagedStackCommandResult {
        if let failure = statusFailure { return try result(for: failure, command: command) }
        guard let projectID = try? projectID(for: command),
              stacks[projectID] == .databaseHealthy else {
            return ManagedStackCommandResult(
                status: .exited(code: 1),
                standardOutput: "",
                standardError: "supabase local development setup is not running."
            )
        }
        return ManagedStackCommandResult(
            status: .exited(code: 0),
            standardOutput: "{}",
            standardError: ""
        )
    }

    private func result(
        for failure: CommandFailure,
        command: CommandSpec
    ) throws -> ManagedStackCommandResult {
        switch failure {
        case let .exit(code):
            return ManagedStackCommandResult(
                status: .exited(code: code),
                standardOutput: "",
                standardError: "failed"
            )
        case let .unavailable(reason):
            throw ManagedStackCommandError.unresolvable(
                command: command.displayCommandLine,
                reason: reason
            )
        }
    }

    /// 実CLIと同じく、`--workdir`（なければ作業ディレクトリ）の設定から対象を決める。
    private func projectID(for command: CommandSpec) throws -> SupabaseProjectID {
        var directory = command.workingDirectory
        if let index = command.arguments.firstIndex(of: "--workdir"),
           command.arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: command.arguments[index + 1])
        }
        return try SupabaseConfigFile.projectID(inConfigDirectory: directory)
    }
}

/// `<directory>/supabase/config.toml` を作る。`project_id`だけを持つ最小構成。
@discardableResult
func writeSupabaseConfig(
    projectID: String,
    in directory: URL,
    extraContent: String = ""
) throws -> URL {
    let configDirectory = directory.appendingPathComponent("supabase", isDirectory: true)
    try FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: true
    )
    let url = configDirectory.appendingPathComponent("config.toml")
    let content = """
        # Supabase config
        project_id = "\(projectID)"
        \(extraContent)
        """
    try Data(content.utf8).write(to: url)
    return url
}

func makeSupabaseService(
    name: String = "Supabase",
    workingDirectory: URL,
    executable: String = "supabase",
    arguments: [String] = ["start"],
    failurePolicy: FailurePolicy = .block
) -> LaunchUnit {
    makeService(
        name: name,
        kind: .supabase,
        ports: [PortSpec(label: "API", port: 54_321, isPrimary: true)],
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        failurePolicy: failurePolicy
    )
}

func readLines(_ url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
}

/// テスト内で使う本物の TCP リスナー。
///
/// ポートを実際に確保した状態を作るために使う。接続を受けた回数を数えるので、
/// 「設定ポートへ接続していないこと」を実測で確かめられる。
final class LocalTCPServer: @unchecked Sendable {
    enum Behavior {
        /// HTTP として応答する。
        case http(status: Int)
        /// 接続は受け付けるが応答しない。
        case silent
    }

    let port: Int
    private let listenDescriptor: Int32
    private let queue = DispatchQueue(label: "jp.devswitcher.tests.tcp")
    private let lock = NSLock()
    private var acceptedDescriptors: [Int32] = []
    private var acceptedConnections = 0
    private var isStopped = false

    /// 接続を受け付けた回数。Dev Switcher が設定ポートへ触っていないことの根拠にする。
    var acceptedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedConnections
    }

    init(behavior: Behavior) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: assigned.sin_port))
        listenDescriptor = descriptor

        queue.async { [descriptor] in
            while true {
                let accepted = accept(descriptor, nil, nil)
                guard accepted >= 0 else { return }
                self.countAccepted()
                switch behavior {
                case let .http(status):
                    var request = [UInt8](repeating: 0, count: 1024)
                    _ = read(accepted, &request, request.count)
                    let body = "ok"
                    let response = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    _ = response.withCString { write(accepted, $0, strlen($0)) }
                    close(accepted)
                case .silent:
                    // 応答しないまま接続を保持する。閉じるとクライアントが即座に失敗し、
                    // 「listen しているのに使えない」状態を再現できない。
                    self.retain(accepted)
                }
            }
        }
    }

    private func countAccepted() {
        lock.lock()
        acceptedConnections += 1
        lock.unlock()
    }

    private func retain(_ descriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if isStopped {
            close(descriptor)
        } else {
            acceptedDescriptors.append(descriptor)
        }
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let descriptors = acceptedDescriptors
        acceptedDescriptors = []
        lock.unlock()

        close(listenDescriptor)
        for descriptor in descriptors {
            close(descriptor)
        }
    }

    deinit { stop() }
}

/// ポート占有の実測を差し替えるための世界。
/// 解放されない・競合しているといった状況をテストから決められるようにする。
actor FakePortWorld {
    private var occupied: [Int: ObservedPortHolder] = [:]
    private var failure: (any Error)?
    private(set) var probedPortSets: [[Int]] = []
    private var onProbe: (@Sendable () async -> Void)?

    init() {}

    func occupy(port: Int, pid: pid_t = 4242, command: String = "node", loginName: String = "someone") {
        occupied[port] = ObservedPortHolder(
            port: port,
            pid: pid,
            processGroupID: pid,
            command: command,
            loginName: loginName
        )
    }

    func release(port: Int) {
        occupied[port] = nil
    }

    func fail(with error: any Error) {
        failure = error
    }

    func setOnProbe(_ handler: @escaping @Sendable () async -> Void) {
        onProbe = handler
    }

    func probe(_ ports: [Int]) async throws -> [ObservedPortHolder] {
        probedPortSets.append(ports.sorted())
        if let onProbe { await onProbe() }
        if let failure { throw failure }
        return ports.compactMap { occupied[$0] }
    }
}

/// ServiceSupervisor が使うPGID単位のポート観測を、成功から失敗へ切り替える。
actor RuntimePortProbeControl {
    private var failure: PortInspectorError?

    func fail(with error: PortInspectorError) {
        failure = error
    }

    func probe(_ processGroupID: pid_t) throws -> [ObservedPort] {
        if let failure { throw failure }
        return []
    }
}

/// テストから任意のタイミングで処理を進めるための門。
actor TestGate {
    private var reached = false
    private var released = false

    func markReached() { reached = true }

    func waitUntilReached(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if reached { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reached
    }

    func release() { released = true }

    func waitForRelease(timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if released { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

func waitUntil(
    timeout: Duration = .seconds(15),
    interval: Duration = .milliseconds(50),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

/// 実プロセスの生死だけをテスト側で追跡し、macOSのprocess情報取得権限に依存させない。
final class ControlledProcessWorld: @unchecked Sendable {
    struct SentSignal: Equatable {
        let processGroupID: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var liveProcessGroups: Set<pid_t> = []
    private var recordedSignals: [SentSignal] = []

    func identity(pid: pid_t, workingDirectory: URL) -> ProcessIdentity? {
        lock.lock()
        liveProcessGroups.insert(pid)
        lock.unlock()
        return ProcessIdentity(
            pid: pid,
            startAbstime: UInt64(pid),
            startedAt: Date(timeIntervalSince1970: TimeInterval(pid)),
            executablePath: "/bin/sleep",
            workingDirectory: workingDirectory
        )
    }

    func startObservation(pid: pid_t) -> ProcessInspector.StartAbstimeObservation {
        lock.lock()
        defer { lock.unlock() }
        return liveProcessGroups.contains(pid) ? .present(UInt64(pid)) : .notPresent
    }

    func groupState(processGroupID: pid_t) -> ProcessInspector.ProcessGroupState {
        lock.lock()
        defer { lock.unlock() }
        guard liveProcessGroups.contains(processGroupID) else { return .members([]) }
        return .members([
            ProcessInspector.ProcessGroupMember(pid: processGroupID, isZombie: false),
        ])
    }

    func send(processGroupID: pid_t, signal: Int32) -> Int32 {
        lock.lock()
        recordedSignals.append(SentSignal(processGroupID: processGroupID, signal: signal))
        liveProcessGroups.remove(processGroupID)
        lock.unlock()
        return kill(-processGroupID, signal)
    }

    var signals: [SentSignal] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSignals
    }

    func clearSignals() {
        lock.lock()
        recordedSignals.removeAll()
        lock.unlock()
    }
}

/// 値が取れるまで待つ。取れなければ nil。
func waitForValue<Value: Sendable>(
    timeout: Duration = .seconds(15),
    interval: Duration = .milliseconds(50),
    _ produce: @Sendable () async -> Value?
) async -> Value? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = await produce() { return value }
        try? await Task.sleep(for: interval)
    }
    return await produce()
}

actor EventLog {
    private(set) var events: [ServiceSupervisor.Event] = []

    func append(_ event: ServiceSupervisor.Event) {
        events.append(event)
    }

    func consume(_ stream: AsyncStream<ServiceSupervisor.Event>) async {
        for await event in stream {
            append(event)
        }
    }

    var lines: [LogLine] {
        events.flatMap { event -> [LogLine] in
            if case let .log(lines) = event { return lines }
            return []
        }
    }

    func text(of stream: LogLine.Stream) -> String {
        lines.filter { $0.stream == stream }.map(\.text).joined(separator: "\n")
    }

    var startedRuntime: ObservedRuntime? {
        for event in events {
            if case let .started(runtime) = event { return runtime }
        }
        return nil
    }

    var exitStatus: ExitStatus? {
        for event in events {
            if case let .exited(status, _, _) = event { return status }
        }
        return nil
    }

    var exitWasRequested: Bool? {
        for event in events {
            if case let .exited(_, requested, _) = event { return requested }
        }
        return nil
    }

    var observedPorts: [ObservedPort] {
        var ports: [ObservedPort] = []
        for event in events {
            if case let .ports(value) = event { ports = value }
        }
        return ports
    }

    var warnings: [String] {
        events.compactMap { event in
            if case let .warning(message) = event { return message }
            return nil
        }
    }
}

struct TestSupportError: Error, CustomStringConvertible {
    let description: String
}

/// 設定ファイルを読まずに、`kind: "supabase"`のサービスから解決済みのスタックを作る。
/// `project_id`は引数の値をそのまま使う。
func makeResolvedSupabaseStack(
    _ service: LaunchUnit,
    projectID: SupabaseProjectID,
    environmentID: UUID = UUID()
) throws -> ResolvedManagedStack {
    guard let configuration = service.derivedSupabaseConfiguration else {
        throw TestSupportError(description: "「\(service.name)」から Supabase の設定を導出できません。")
    }
    return ResolvedManagedStack(
        environmentID: environmentID,
        stackID: service.id,
        stackName: service.name,
        configuration: .supabase(
            SupabaseResolvedConfiguration(derived: configuration, projectID: projectID)
        ),
        sourceConfiguration: .supabase(
            SupabaseStackConfiguration(start: service.start, stop: service.stop)
        )
    )
}

/// 種類が`supabase`の`ManagedStackIdentity`を作る。値が不正なら throw する。
func makeSupabaseIdentity(_ value: String) throws -> ManagedStackIdentity {
    try ManagedStackIdentity(type: .supabase, value: value)
}

/// `SupabaseProjectID`を作る。値が不正なら throw する。
func makeSupabaseProjectID(_ value: String) throws -> SupabaseProjectID {
    guard let projectID = SupabaseProjectID(rawValue: value) else {
        throw TestSupportError(description: "テスト用の project_id が不正です: \(value)")
    }
    return projectID
}

/// 起動コマンド`supabase start`を`directory`で実行する構成の同一性。
func makeSupabaseFingerprint(_ directory: String = "/tmp/demo") -> SupabaseLifecycleFingerprint {
    SupabaseLifecycleFingerprint(
        start: CommandSpec(
            executable: "supabase",
            arguments: ["start"],
            workingDirectory: URL(fileURLWithPath: directory)
        ),
        configDirectory: URL(fileURLWithPath: directory)
    )
}

/// 種類共通の契約だけで Registry・Coordinator を動かすためのフェイク driver。
///
/// 外部コマンドを実行せず、呼び出しを記録する。`start`と`stop`はこの driver の状態を変える。
actor FakeManagedStackDriver: ManagedStackDriver {
    enum Call: Equatable, Sendable {
        case observe(known: [ManagedStackIdentity])
        case start(ManagedStackIdentity, known: [ManagedStackIdentity])
        case stop(ManagedStackIdentity, context: ManagedStackIdentity, known: [ManagedStackIdentity])
    }

    nonisolated let type: ManagedStackType
    private var states: [ManagedStackIdentity: ManagedStackState]
    private var observationFailure: String?
    private(set) var calls: [Call] = []
    private(set) var latestSnapshot: ManagedStackSnapshot?

    init(type: ManagedStackType, states: [ManagedStackIdentity: ManagedStackState] = [:]) {
        precondition(
            states.keys.allSatisfy { $0.type == type },
            "\(type.rawValue) の driver に別の種類の状態が含まれています。"
        )
        self.type = type
        self.states = states
    }

    func setState(_ identity: ManagedStackIdentity, _ state: ManagedStackState?) {
        precondition(identity.type == type, "\(type.rawValue) の driver に別の種類の状態を設定しました。")
        states[identity] = state
    }

    func failObservation(_ reason: String?) { observationFailure = reason }
    func resetCalls() { calls.removeAll() }

    func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot {
        calls.append(.observe(known: known.map(\.identity)))
        let snapshot: ManagedStackSnapshot
        if let observationFailure {
            snapshot = ManagedStackSnapshot(type: type, unobservable: observationFailure)
        } else {
            snapshot = ManagedStackSnapshot(
                type: type,
                observations: states.map { ManagedStackObservation(identity: $0.key, state: $0.value) }
            )
        }
        latestSnapshot = snapshot
        return snapshot
    }

    func start(_ stack: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine] {
        calls.append(.start(stack.identity, known: known.map(\.identity)))
        states[stack.identity] = .running
        return []
    }

    func stop(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine] {
        calls.append(.stop(identity, context: context.identity, known: known.map(\.identity)))
        states[identity] = nil
        return []
    }
}

/// 管理下へ入ったSupabaseの手掛かりを、設定ファイルを読まずに作る。構成を導出できないサービスなら throw する。
func makeManagedStackHint(
    projectID: UUID,
    service: LaunchUnit,
    supabaseProjectID: SupabaseProjectID,
    relationship: ManagedStackRelationship
) throws -> ManagedStackHint {
    let stack = try makeResolvedSupabaseStack(
        service,
        projectID: supabaseProjectID,
        environmentID: projectID
    )
    return ManagedStackHint(stack, relationship: relationship)
}

extension LaunchUnit {
    /// アダプタ経由で導出した Supabase の設定。導出できなければ nil。
    var derivedSupabaseConfiguration: SupabaseDerivedConfiguration? {
        guard let definition = managedStackDefinition,
              case let .supabase(configuration)? = definition.configuration
                  .derived(workingDirectory: start.workingDirectory) else {
            return nil
        }
        return configuration
    }
}
