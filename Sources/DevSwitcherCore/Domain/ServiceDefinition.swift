import Foundation

/// 起動対象かどうかと、失敗時に全体を止めるかは独立した判断なので型を分ける。
public enum FailurePolicy: String, Codable, Sendable, CaseIterable {
    case block
    case `continue`

    public var displayName: String {
        switch self {
        case .block: L10n.text("開発環境全体を失敗にする")
        case .continue: L10n.text("一部停止として続行する")
        }
    }
}

public struct ServiceDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var tag: String?
    /// workerやwatcherはポートを持たないため、空配列を有効とする。
    public var ports: [PortSpec]
    public var start: CommandSpec
    /// 指定時は SIGTERM の代わりに実行し、対象グループの終了を実測する。
    public var stop: CommandSpec?
    public var enabledByDefault: Bool
    public var failurePolicy: FailurePolicy

    public init(
        id: UUID = UUID(),
        name: String,
        tag: String? = nil,
        ports: [PortSpec],
        start: CommandSpec,
        stop: CommandSpec? = nil,
        enabledByDefault: Bool,
        failurePolicy: FailurePolicy
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.ports = ports
        self.start = start
        self.stop = stop
        self.enabledByDefault = enabledByDefault
        self.failurePolicy = failurePolicy
    }

    public var stopMethod: ProcessStopMethod { stop.map(ProcessStopMethod.command) ?? .signal }

    public var primaryPort: PortSpec? {
        ports.first(where: \.isPrimary)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, tag, ports, start, stop, enabledByDefault, failurePolicy
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tag = try c.optional(String.self, forKey: .tag)
        ports = try c.decode([PortSpec].self, forKey: .ports)
        start = try c.decode(CommandSpec.self, forKey: .start)
        stop = try c.optional(CommandSpec.self, forKey: .stop)
        enabledByDefault = try c.decode(Bool.self, forKey: .enabledByDefault)
        failurePolicy = try c.decode(FailurePolicy.self, forKey: .failurePolicy)
    }
}
