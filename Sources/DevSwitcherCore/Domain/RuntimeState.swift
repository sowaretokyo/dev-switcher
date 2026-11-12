import Foundation

/// Milestone 2 は HTTP 到達性を確認しない。表示できるのは「プロセスを起こして、
/// 初期観測のあいだ終了しなかった」という事実までなので、`.healthy` も「起動済み」と表示する。
/// アプリが応答するかどうかは保証しない。
public enum ServicePhase: Equatable, Sendable {
    /// 今回の起動対象から外したサービス。失敗でも停止でもないため、警告や一部停止に含めない。
    case excluded
    case stopped
    case starting
    /// プロセスを起こした直後。初期観測がまだ終わっていない段階。
    case running
    /// 初期観測を通過した。ここで初めて「起動済み」と表示してよい。
    case healthy
    case stopping
    case failed(reason: String)
    case residual

    /// 状態を色だけで伝えないため、常にテキストも返す。
    public var label: String {
        switch self {
        case .excluded: L10n.text("対象外")
        case .stopped: L10n.text("停止中")
        case .starting: L10n.text("起動処理中")
        case .running: L10n.text("起動中")
        case .healthy: L10n.text("起動済み")
        case .stopping: L10n.text("停止処理中")
        case .failed: L10n.text("失敗")
        case .residual: L10n.text("残存あり")
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
    /// `failurePolicy: continue` のサービスだけが停止している。起動済みの一種。
    case degraded(stoppedServices: [String])
    case stopping
    /// 切替の停止・ゲート・起動のいずれか。この間は他プロジェクトを操作しない。
    case switching
    case failed(reason: String)
    case residual

    public var label: String {
        switch self {
        case .stopped: L10n.text("停止中")
        case .starting: L10n.text("起動中")
        case .running: L10n.text("起動済み")
        case .degraded: L10n.text("一部停止")
        case .stopping: L10n.text("停止処理中")
        case .switching: L10n.text("切替中")
        case .failed: L10n.text("失敗")
        case .residual: L10n.text("残存あり")
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
