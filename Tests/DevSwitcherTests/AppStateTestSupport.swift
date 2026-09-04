import Darwin
@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation

/// テストからログインシェルを起動しないための固定環境。
let fixedShellEnvironment = try! ShellEnvironment(
    variables: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
)

/// テストを実時間で待たせないための設定。猶予と観測窓だけを縮め、判定は変えない。
let fastCoordinatorOptions = SwitchCoordinator.Options(
    releaseTimeout: .seconds(2),
    stopGrace: .seconds(2),
    startupObservationWindow: .milliseconds(200),
    startupPollInterval: .milliseconds(50),
    gatePollInterval: .milliseconds(50)
)

/// 保存先と実行環境を必ず一時ディレクトリへ差し替えた `AppState`。
/// 既定のままだと、設定・手掛かりに加えてサービスのログまで
/// 利用者の Application Support へ書き込む。
@MainActor
func makeAppState(
    directory: URL,
    registry providedRegistry: RuntimeRegistry? = nil,
    environmentLoader: @escaping RuntimeRegistry.ShellEnvironmentLoader = {
        fixedShellEnvironment
    },
    handoffInspector: HandoffInspector = HandoffInspector(),
    hintStore: (any RuntimeHintPersisting)? = nil,
    options: SwitchCoordinator.Options = fastCoordinatorOptions
) -> AppState {
    let registry = providedRegistry ?? RuntimeRegistry(
        portPollInterval: .seconds(60),
        // ログの出力先も一時ディレクトリにする。
        logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
        environmentLoader: environmentLoader
    )
    return AppState(
        registry: registry,
        store: ProjectStore(directory: directory),
        hintStore: hintStore ?? RuntimeHintStore(directory: directory),
        handoffInspector: handoffInspector,
        coordinatorOptions: options
    )
}

func makeStoredHint(
    projectID: UUID,
    serviceID: UUID,
    serviceName: String = "Worker",
    pid: pid_t = 999_999,
    startAbstime: UInt64 = 1,
    directory: URL
) -> RuntimeHint {
    let anchor = ProcessAnchor(pid: pid, startAbstime: startAbstime)
    return RuntimeHint(
        projectID: projectID,
        serviceID: serviceID,
        serviceName: serviceName,
        processGroupID: anchor.pid,
        leader: anchor,
        groupEvidence: ProcessGroupEvidence(
            bootSessionID: "TEST-BOOT-SESSION",
            anchors: [anchor]
        ),
        executablePath: "/bin/sleep",
        workingDirectory: directory,
        observedPorts: .observed([])
    )
}

func makeCandidate(for hint: RuntimeHint) -> HandoffCandidate {
    HandoffCandidate(
        hint: hint,
        identity: ProcessIdentity(
            pid: hint.leader.pid,
            startAbstime: hint.leader.startAbstime,
            startedAt: Date(timeIntervalSince1970: 1),
            executablePath: hint.executablePath,
            workingDirectory: hint.workingDirectory
        ),
        evidence: hint.groupEvidence,
        observedPorts: []
    )
}

func makeRegistry(
    directory: URL,
    observations: ProcessObservationControl,
    signalSender: (@Sendable (pid_t, Int32) -> Int32)? = nil,
    portProbe: @escaping ServiceSupervisor.PortProbe = { _ in [] }
) -> RuntimeRegistry {
    RuntimeRegistry(
        portPollInterval: .seconds(60),
        logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
        environmentLoader: { fixedShellEnvironment },
        portProbe: portProbe,
        signalSender: signalSender ?? { kill(-$0, $1) },
        groupStateProbe: { observations.groupState(processGroupID: $0) },
        startAbstimeProbe: { observations.startObservation(pid: $0) },
        bootSessionProbe: { observations.bootSession() }
    )
}

/// 実プロセスを使わずに「引き継げる候補が1件ある」状況を作る。
/// 停止シグナルは記録するだけで、送出先の観測を空へ切り替えて成功を再現する。
struct SyntheticFixture {
    let project: ProjectDefinition
    let hint: RuntimeHint
    let observations: ProcessObservationControl
    let signals: SignalRecorder
    let registry: RuntimeRegistry
    let inspector: HandoffInspector

    var service: ServiceDefinition { project.services[0] }
}

func makeSyntheticFixture(
    directory: URL,
    projectName: String = "Bell",
    pid: pid_t = 45_001,
    startAbstime: UInt64 = 501,
    portProbe: @escaping ServiceSupervisor.PortProbe = { _ in [] }
) -> SyntheticFixture {
    let project = makeWorkerProject(name: projectName, directory: directory)
    let hint = makeStoredHint(
        projectID: project.id,
        serviceID: project.services[0].id,
        serviceName: project.services[0].name,
        pid: pid,
        startAbstime: startAbstime,
        directory: directory
    )
    let observations = ProcessObservationControl(
        startObservations: [hint.leader.pid: .present(hint.leader.startAbstime)],
        groupStates: [
            hint.processGroupID: .members([
                ProcessInspector.ProcessGroupMember(pid: hint.leader.pid, isZombie: false),
            ]),
        ]
    )
    // 停止できたことを決定的に再現する。観測を切り替えないと猶予いっぱい待つ。
    let signals = SignalRecorder { processGroupID, _ in
        observations.setGroupState(.members([]), for: processGroupID)
        observations.setStartObservation(.notPresent, for: processGroupID)
    }
    let registry = makeRegistry(
        directory: directory,
        observations: observations,
        signalSender: { signals.send($0, $1) },
        portProbe: portProbe
    )
    let inspector = HandoffInspector(
        startAbstimeProbe: { observations.startObservation(pid: $0) },
        startTimeProbe: { _ in 1_000_000 },
        executablePathProbe: { _ in "/bin/sleep" },
        workingDirectoryProbe: { _ in directory },
        portProbe: { _ in [] },
        groupStateProbe: { observations.groupState(processGroupID: $0) },
        bootSessionProbe: { observations.bootSession() }
    )
    return SyntheticFixture(
        project: project,
        hint: hint,
        observations: observations,
        signals: signals,
        registry: registry,
        inspector: inspector
    )
}

enum TestFactoryError: Error {
    case unavailable
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// hintの読み書きを決定的に失敗させる保存先。
///
/// ファイル権限で失敗を作ると、実行ユーザー（rootなど）によって結果が変わるうえ、
/// 「起動前の保存は成功し、起動後の保存だけ失敗する」という順序を作れない。
/// 失敗させない限り、実体の`RuntimeHintStore`へそのまま委譲する。
final class ControllableHintStore: RuntimeHintPersisting, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case loadRefused
        case saveRefused

        var description: String {
            switch self {
            case .loadRefused: "テスト用の保存先が読み込みを拒否しました。"
            case .saveRefused: "テスト用の保存先が保存を拒否しました。"
            }
        }
    }

    private let backing: RuntimeHintStore
    private let lock = NSLock()
    private var loadFails = false
    /// 何回目の save を失敗させるか（1始まり）。nil なら失敗させない。
    private var saveFailurePredicate: (@Sendable (Int) -> Bool)?
    private var saveCount = 0

    init(directory: URL) {
        backing = RuntimeHintStore(directory: directory)
    }

    var fileURL: URL { backing.fileURL }

    var saveAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCount
    }

    func failLoads() {
        lock.lock()
        loadFails = true
        lock.unlock()
    }

    func allowLoads() {
        lock.lock()
        loadFails = false
        lock.unlock()
    }

    func failSaves(where predicate: @escaping @Sendable (Int) -> Bool) {
        lock.lock()
        saveFailurePredicate = predicate
        lock.unlock()
    }

    func failAllSaves() {
        failSaves { _ in true }
    }

    func allowSaves() {
        lock.lock()
        saveFailurePredicate = nil
        lock.unlock()
    }

    func load() throws -> RuntimeHintsLoad {
        lock.lock()
        let refuse = loadFails
        lock.unlock()
        if refuse { throw Failure.loadRefused }
        return try backing.load()
    }

    func save(_ hints: [RuntimeHint], legacy: [LegacyRuntimeHint]) throws {
        lock.lock()
        saveCount += 1
        let refuse = saveFailurePredicate?(saveCount) ?? false
        lock.unlock()
        if refuse { throw Failure.saveRefused }
        try backing.save(hints, legacy: legacy)
    }
}

/// 送出したシグナルを記録し、実在しないPIDへ本物のシグナルを送らないようにする。
/// `onSignal` で観測結果を切り替えれば、停止の成否を決定的に作れる。
final class SignalRecorder: @unchecked Sendable {
    struct Sent: Equatable {
        let processGroupID: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var records: [Sent] = []
    private let onSignal: (@Sendable (pid_t, Int32) -> Void)?

    init(onSignal: (@Sendable (pid_t, Int32) -> Void)? = nil) {
        self.onSignal = onSignal
    }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func send(_ processGroupID: pid_t, _ signal: Int32) -> Int32 {
        lock.lock()
        records.append(Sent(processGroupID: processGroupID, signal: signal))
        lock.unlock()
        onSignal?(processGroupID, signal)
        return 0
    }
}

/// Registry登録後に観測結果だけを切り替え、終了時保存の失敗を決定的に再現する。
final class ProcessObservationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var bootSessionID: String?
    private var startObservations: [pid_t: ProcessInspector.StartAbstimeObservation]
    private var groupStates: [pid_t: ProcessInspector.ProcessGroupState]

    init(
        bootSessionID: String? = "TEST-BOOT-SESSION",
        startObservations: [pid_t: ProcessInspector.StartAbstimeObservation],
        groupStates: [pid_t: ProcessInspector.ProcessGroupState]
    ) {
        self.bootSessionID = bootSessionID
        self.startObservations = startObservations
        self.groupStates = groupStates
    }

    func setBootSessionID(_ value: String?) {
        lock.lock()
        bootSessionID = value
        lock.unlock()
    }

    func setStartObservation(
        _ observation: ProcessInspector.StartAbstimeObservation,
        for pid: pid_t
    ) {
        lock.lock()
        startObservations[pid] = observation
        lock.unlock()
    }

    func setGroupState(_ state: ProcessInspector.ProcessGroupState, for processGroupID: pid_t) {
        lock.lock()
        groupStates[processGroupID] = state
        lock.unlock()
    }

    func bootSession() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bootSessionID
    }

    func startObservation(pid: pid_t) -> ProcessInspector.StartAbstimeObservation {
        lock.lock()
        defer { lock.unlock() }
        return startObservations[pid] ?? .notPresent
    }

    func groupState(processGroupID: pid_t) -> ProcessInspector.ProcessGroupState {
        lock.lock()
        defer { lock.unlock() }
        return groupStates[processGroupID] ?? .members([])
    }
}

func makeTemporaryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("devswitcher-appstate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 任意のタイミングで処理を進めるための門。
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

    func waitForRelease(timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if released { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// 武装したときだけ処理を止める門。
///
/// 準備段階と検証対象が同じ経路（ポート実測など）を通る場合に使う。
/// `TestGate` は最初から止めるので、準備を済ませてから止めたいときはこちらにする。
actor ArmedGate {
    private var armed = false
    private var reached = false
    private var released = false

    func arm() {
        armed = true
        reached = false
        released = false
    }

    /// 武装していれば、解放されるまで待つ。していなければ素通りする。
    func passOrWait() async {
        guard armed else { return }
        reached = true
        while !released {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilReached(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if reached { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reached
    }

    func release() { released = true }
}

/// 空きポート番号を取るためだけの一時的な listen。番号を得たらすぐ解放する。
final class LocalPortReservation {
    let port: Int
    private let descriptor: Int32
    private var isReleased = false

    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var reuse: Int32 = 1
        setsockopt(
            socketDescriptor, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
            let code = errno
            close(socketDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: assigned.sin_port))
        descriptor = socketDescriptor
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        close(descriptor)
    }

    deinit { release() }
}

func waitForCondition(
    timeout: Duration = .seconds(15),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func waitForValue<Value: Sendable>(
    timeout: Duration = .seconds(15),
    _ produce: @Sendable () -> Value?
) async -> Value? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = produce() { return value }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return produce()
}

func makeWorkerProject(
    name: String = "Bell",
    directory: URL,
    serviceNames: [String] = ["Worker"],
    arguments: [String] = ["120"],
    executable: String = "/bin/sleep",
    ports: [PortSpec] = []
) -> ProjectDefinition {
    ProjectDefinition(
        name: name,
        color: .blue,
        directory: directory,
        services: serviceNames.map { serviceName in
            ServiceDefinition(
                name: serviceName,
                kind: .worker,
                ports: ports,
                start: CommandSpec(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: directory
                ),
                enabledByDefault: true,
                failurePolicy: .block
            )
        }
    )
}

/// 実プロセスを測って現行形式の手掛かりを作る。テストが v1 の形を再現しないようにする。
func makeMeasuredHint(
    project: ProjectDefinition,
    serviceIndex: Int = 0,
    pid: pid_t,
    processGroupID: pid_t,
    directory: URL
) -> RuntimeHint? {
    guard let leader = ProcessAnchor.measure(pid: pid),
          let evidence = ProcessGroupIdentification.captureEvidence(
              processGroupID: processGroupID
          )
    else { return nil }
    let service = project.services[serviceIndex]
    return RuntimeHint(
        projectID: project.id,
        serviceID: service.id,
        serviceName: service.name,
        processGroupID: processGroupID,
        leader: leader,
        groupEvidence: evidence,
        executablePath: ProcessInspector.executablePath(pid: pid) ?? "/bin/sh",
        workingDirectory: directory,
        observedPorts: .observed([])
    )
}
