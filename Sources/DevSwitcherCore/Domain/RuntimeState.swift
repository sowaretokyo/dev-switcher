import Foundation

/// ヘルスチェック前のプロセス生存を「正常稼働」と誤認させないため、`.running` は「起動中」と表示し、
/// ヘルスチェックを通過した`.healthy`だけを「稼働中」とする。
public enum ServicePhase: Equatable, Sendable {
    /// 今回の起動対象から外したサービス。失敗でも停止でもないため、警告や一部停止に含めない。
    case excluded
    case stopped
    case starting
    /// プロセスは起動済み。listen していてもヘルスチェック未通過の段階。
    case running
    /// ヘルスチェックを通過した。ここで初めて「稼働中」と表示してよい。
    case healthy
    case stopping
    case failed(reason: String)
    case residual

    /// 状態を色だけで伝えないため、常にテキストも返す。
    public var label: String {
        switch self {
        case .excluded: "対象外"
        case .stopped: "停止中"
        case .starting: "起動処理中"
        case .running: "起動中"
        case .healthy: "稼働中"
        case .stopping: "終了中"
        case .failed: "失敗"
        case .residual: "残存あり"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .running, .healthy, .stopping, .residual: true
        case .excluded, .stopped, .failed: false
        }
    }
}

/// プロジェクト全体の状態。サービスの状態をそのまま流用すると「一部停止」を表現できない。
public enum ProjectPhase: Equatable, Sendable {
    case stopped
    case starting
    case running
    /// `failurePolicy: continue` のサービスだけが停止している。稼働中の一種。
    case degraded(stoppedServices: [String])
    case stopping
    /// 切替の停止・ゲート・起動のいずれか。この間は他プロジェクトを操作しない。
    case switching
    case failed(reason: String)
    case residual

    public var label: String {
        switch self {
        case .stopped: "停止中"
        case .starting: "起動中"
        case .running: "稼働中"
        case .degraded: "一部停止"
        case .stopping: "終了中"
        case .switching: "切替中"
        case .failed: "失敗"
        case .residual: "残存あり"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .running, .degraded, .stopping, .switching, .residual: true
        case .stopped, .failed: false
        }
    }
}

public enum ProcessManagement: String, Sendable {
    /// Dev Switcher が起動した子プロセス。プロセスグループごと管理する。
    case childProcess
    /// アプリ再起動後に実測で照合して引き継いだプロセス。子ではないため回収予約を持てない。
    case adopted
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
