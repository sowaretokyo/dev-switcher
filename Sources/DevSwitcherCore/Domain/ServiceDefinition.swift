import Foundation

public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case web
    case expo
    case supabase
    case inngest
    case docker
    case worker
    case other

    public var displayName: String {
        switch self {
        case .web: "Web"
        case .expo: "Expo"
        case .supabase: "Supabase"
        case .inngest: "Inngest"
        case .docker: "Docker"
        case .worker: "Worker / Watcher"
        case .other: "その他"
        }
    }
}

/// 起動対象かどうかと、失敗時に全体を止めるかは独立した判断なので型を分ける。
public enum FailurePolicy: String, Codable, Sendable, CaseIterable {
    case block
    case `continue`

    public var displayName: String {
        switch self {
        case .block: "開発環境全体を失敗にする"
        case .continue: "一部停止として続行する"
        }
    }
}

public struct ServiceDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ServiceKind
    /// workerやwatcherはポートを持たないため、空配列を有効とする。
    public var ports: [PortSpec]
    public var start: CommandSpec
    /// 起動コマンド自身が終了してもサービスが残るもののカスタム終了方法。
    /// MVPでは未対応。通常プロセスはnilならプロセスグループで停止し、Supabaseは
    /// nilの場合だけ起動コマンドと同じCLIから`stop`を導出する。
    public var stop: CommandSpec?
    public var enabledByDefault: Bool
    public var failurePolicy: FailurePolicy

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ServiceKind,
        ports: [PortSpec],
        start: CommandSpec,
        stop: CommandSpec? = nil,
        enabledByDefault: Bool,
        failurePolicy: FailurePolicy
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ports = ports
        self.start = start
        self.stop = stop
        self.enabledByDefault = enabledByDefault
        self.failurePolicy = failurePolicy
    }

    public var primaryPort: PortSpec? {
        ports.first(where: \.isPrimary)
    }

    /// 管理対象スタックとして扱うサービスなら、その定義（docs/ARCHITECTURE.md 4.3 のアダプタ）。
    /// 設定の妥当性にかかわらず作る。不備は`ManagedStackConfiguration`の検証が返す。
    public var managedStackDefinition: ManagedStackDefinition? {
        guard kind == .supabase else { return nil }
        return ManagedStackDefinition(
            id: id,
            name: name,
            configuration: .supabase(SupabaseStackConfiguration(start: start, stop: stop)),
            ports: ports,
            enabledByDefault: enabledByDefault,
            failurePolicy: failurePolicy
        )
    }

    /// 停止方法がプロセスグループのシグナルで完結するか。
    public var usesProcessGroupStop: Bool {
        managedStackDefinition == nil && stop == nil
    }
}
