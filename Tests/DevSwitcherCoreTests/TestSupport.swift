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
) -> ServiceDefinition {
    ServiceDefinition(
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
    name: String = "Bell",
    directory: URL,
    services: [ServiceDefinition]? = nil,
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
) -> ServiceDefinition {
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
) -> ServiceDefinition {
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
            if case let .exited(status, _) = event { return status }
        }
        return nil
    }

    var exitWasRequested: Bool? {
        for event in events {
            if case let .exited(_, requested) = event { return requested }
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
