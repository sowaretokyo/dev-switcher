import Foundation

/// 実行・表示で共有する起動単位。保存するプロセスとスタックの定義は別々に保つ。
public enum LaunchUnit: Equatable, Sendable, Identifiable {
    case stack(ManagedStackDefinition, workingDirectory: URL)
    case process(ServiceDefinition)

    public init(_ service: ServiceDefinition) { self = .process(service) }
    public var id: UUID {
        get { switch self { case let .stack(value, _): value.id; case let .process(value): value.id } }
        set {
            switch self {
            case var .process(value): value.id = newValue; self = .process(value)
            case let .stack(original, directory): var value = original; value.id = newValue; self = .stack(value, workingDirectory: directory)
            }
        }
    }
    public var name: String {
        get { switch self { case let .stack(value, _): value.name; case let .process(value): value.name } }
        set {
            switch self {
            case var .process(value): value.name = newValue; self = .process(value)
            case let .stack(original, directory): var value = original; value.name = newValue; self = .stack(value, workingDirectory: directory)
            }
        }
    }
    public var ports: [PortSpec] {
        get { switch self { case let .stack(value, _): value.ports; case let .process(value): value.ports } }
        set {
            switch self {
            case var .process(value): value.ports = newValue; self = .process(value)
            case let .stack(original, directory): var value = original; value.ports = newValue; self = .stack(value, workingDirectory: directory)
            }
        }
    }
    public var primaryPort: PortSpec? { ports.first(where: \.isPrimary) }
    public var enabledByDefault: Bool {
        get { switch self { case let .stack(value, _): value.enabledByDefault; case let .process(value): value.enabledByDefault } }
        set {
            switch self {
            case var .process(value): value.enabledByDefault = newValue; self = .process(value)
            case let .stack(original, directory): var value = original; value.enabledByDefault = newValue; self = .stack(value, workingDirectory: directory)
            }
        }
    }
    public var failurePolicy: FailurePolicy {
        get { switch self { case let .stack(value, _): value.failurePolicy; case let .process(value): value.failurePolicy } }
        set {
            switch self {
            case var .process(value): value.failurePolicy = newValue; self = .process(value)
            case let .stack(original, directory): var value = original; value.failurePolicy = newValue; self = .stack(value, workingDirectory: directory)
            }
        }
    }
    public var managedStackDefinition: ManagedStackDefinition? {
        if case let .stack(value, _) = self { return value }; return nil
    }
    public var processDefinition: ServiceDefinition? {
        if case let .process(value) = self { return value }; return nil
    }
    public var workingDirectory: URL {
        switch self { case let .stack(_, directory): directory; case let .process(value): value.start.workingDirectory }
    }
    public var displayTag: String? {
        switch self { case let .stack(value, _): value.type.displayName; case let .process(value): value.tag }
    }
    public var commandDescription: String {
        switch self {
        case let .process(value): value.start.displayCommandLine
        case let .stack(value, _):
            switch value.configuration {
            case let .supabase(config): config.start.displayCommandLine
            case let .dockerCompose(config): "docker compose up -d " + config.upArguments.joined(separator: " ")
            }
        }
    }
}

extension ProjectDefinition {
    public var launchUnits: [LaunchUnit] {
        managedStacks.map { stack in
            guard let directory = workingDirectories.first(where: { $0.stackIDs.contains(stack.id) }) else {
                preconditionFailure("スタックの作業ディレクトリがありません。")
            }
            return .stack(stack, workingDirectory: directory.directory)
        } + startupOrder.map(LaunchUnit.process)
    }
    public var enabledLaunchUnits: [LaunchUnit] { launchUnits.filter { isEnabledNow($0.id) } }
    public var shutdownUnits: [LaunchUnit] {
        shutdownOrder.map(LaunchUnit.process) + launchUnits.filter { $0.managedStackDefinition != nil }.reversed()
    }
    public func entry(id: UUID) -> LaunchUnit? { launchUnits.first { $0.id == id } }
}
