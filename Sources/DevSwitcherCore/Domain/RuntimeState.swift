import Foundation

/// ヘルスチェック前のプロセス生存を「正常稼働」と誤認させないため、`.running` は「起動中」と表示する。
public enum ServicePhase: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed(reason: String)
    case residual

    /// 状態を色だけで伝えないため、常にテキストも返す。
    public var label: String {
        switch self {
        case .stopped: "停止中"
        case .starting: "起動処理中"
        case .running: "起動中"
        case .stopping: "終了中"
        case .failed: "失敗"
        case .residual: "残存あり"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping, .residual: true
        case .stopped, .failed: false
        }
    }
}

public enum ProcessManagement: String, Sendable {
    case childProcess
}

/// 停止判断に設定値や古い保存値を使わないため、実プロセスの観測結果を別型で持つ。
/// ディスク上の稼働状態を信用しないよう、意図的に `Codable` にしない。
public struct ObservedRuntime: Equatable, Sendable {
    public var serviceID: UUID
    public var identity: ProcessIdentity
    public var processGroupID: pid_t
    public var observedPorts: [ObservedPort]
    public var startedAt: Date
    public var management: ProcessManagement

    public init(
        serviceID: UUID,
        identity: ProcessIdentity,
        processGroupID: pid_t,
        observedPorts: [ObservedPort],
        startedAt: Date,
        management: ProcessManagement
    ) {
        self.serviceID = serviceID
        self.identity = identity
        self.processGroupID = processGroupID
        self.observedPorts = observedPorts
        self.startedAt = startedAt
        self.management = management
    }
}
