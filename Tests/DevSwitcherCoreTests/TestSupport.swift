import Foundation
@testable import DevSwitcherCore

/// 実際の `zsh -lic` を確認するテストは `LoginShellEnvironmentTests` の1件だけにしている。
/// 各テストがログインシェルを起動すると、利用者の zsh 設定次第で並列実行が不安定になるため。
let fixedShellEnvironment = ShellEnvironment(
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
        enabledByDefault: enabledByDefault,
        failurePolicy: failurePolicy
    )
}

func makeProject(
    name: String = "Bell",
    directory: URL,
    services: [ServiceDefinition]? = nil
) -> ProjectDefinition {
    ProjectDefinition(
        name: name,
        color: .blue,
        directory: directory,
        services: services ?? [makeService(workingDirectory: directory)]
    )
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
