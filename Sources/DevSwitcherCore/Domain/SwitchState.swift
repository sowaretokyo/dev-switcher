import Darwin
import Foundation

/// 切替の進行状態。停止・解放確認・起動を別のケースにして、
/// 「どこで止まったか」が画面と失敗理由の両方から分かるようにする。
public enum SwitchState: Equatable, Sendable {
    case idle
    case stopping(service: String, index: Int, total: Int)
    /// ゲート。停止元が実際に握っていたポートの解放待ち。
    case verifyingRelease(released: Int, total: Int)
    case starting(service: String, index: Int, total: Int)
    /// プロセスを起こした直後の観測。ここを通過して初めて起動成功として扱う。
    case observingStartup(service: String)
    /// 起動失敗後の巻き戻し。今回起動したサービスだけを停止する。
    case rollingBack(service: String)
    case completed

    /// 起動フェーズへ入ったか。入った後は中止を受け付けない（DESIGN.md I-4）。
    public var hasEnteredStartPhase: Bool {
        switch self {
        case .starting, .observingStartup, .rollingBack, .completed: true
        case .idle, .stopping, .verifyingRelease: false
        }
    }

    public var label: String {
        switch self {
        case .idle: "待機中"
        case let .stopping(service, index, total): "\(service) を停止（\(index)/\(total)）"
        case let .verifyingRelease(released, total): "停止元のポート解放を確認（\(released)/\(total)）"
        case let .starting(service, index, total): "\(service) を起動（\(index)/\(total)）"
        case let .observingStartup(service): "\(service) の起動を確認"
        case let .rollingBack(service): "\(service) を停止（巻き戻し）"
        case .completed: "完了"
        }
    }
}

/// ポートを握っているプロセスの所有区分。出せる操作を型から導く（DESIGN.md 決定 c）。
public enum PortOwnership: Equatable, Sendable {
    /// Dev Switcher が起動または引き継いだプロセス。通常の自動停止対象。
    case ownedByUs(serviceID: UUID, serviceName: String)
    /// 同一利用者の外部プロセス。表示はするが、Dev Switcher から signal は送らない。
    case external
    /// 別利用者またはシステム管理下。終了操作を提供しない。
    case systemOwned

    public var label: String {
        switch self {
        case let .ownedByUs(_, serviceName): "Dev Switcher（\(serviceName)）"
        case .external: "外部プロセス"
        case .systemOwned: "システムまたは別ユーザー"
        }
    }

    /// Dev Switcher から終了操作を提供してよいか。
    public var canOfferTermination: Bool {
        switch self {
        case .ownedByUs: true
        case .external, .systemOwned: false
        }
    }
}

/// 競合したポートを名指しするために、ポート単位で保持する（DESIGN.md 決定 g）。
public struct ResolvedPortHolder: Equatable, Sendable {
    public let port: Int
    public let pid: pid_t
    public let command: String?
    public let ownership: PortOwnership

    public init(port: Int, pid: pid_t, command: String?, ownership: PortOwnership) {
        self.port = port
        self.pid = pid
        self.command = command
        self.ownership = ownership
    }

    public var description: String {
        let commandLabel = command ?? "コマンド取得不能"
        return ":\(port) — PID \(pid) \(commandLabel)（\(ownership.label)）"
    }
}

public struct ServiceFact: Equatable, Sendable {
    public let serviceID: UUID
    public let name: String
    public let phase: ServicePhase
    /// 実測ポート。設定値ではない。
    public let observedPorts: ObservedPortRecord

    public init(
        serviceID: UUID,
        name: String,
        phase: ServicePhase,
        observedPorts: ObservedPortRecord
    ) {
        self.serviceID = serviceID
        self.name = name
        self.phase = phase
        self.observedPorts = observedPorts
    }
}

public struct ProjectFact: Equatable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let phase: ProjectPhase
    public let services: [ServiceFact]

    public init(
        projectID: UUID,
        projectName: String,
        phase: ProjectPhase,
        services: [ServiceFact]
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.phase = phase
        self.services = services
    }

    /// 「Bell は停止しました。」のように、いまどうなっているかを1行で断言する。
    public var statement: String {
        switch phase {
        case .stopped: "「\(projectName)」は停止しました。"
        case .starting: "「\(projectName)」は起動処理の途中です。"
        case .running: "「\(projectName)」は起動済みです。"
        case let .degraded(stoppedServices):
            "「\(projectName)」は一部停止です（停止中: \(stoppedServices.joined(separator: " / "))）。"
        case .stopping: "「\(projectName)」は終了処理の途中です。"
        case .switching: "「\(projectName)」は切替処理の途中です。"
        case let .failed(reason): "「\(projectName)」は失敗しました（\(reason)）。"
        case .residual: "「\(projectName)」に停止しきれていないプロセスが残っています。"
        }
    }
}

/// 失敗時に「両方のプロジェクトが今どうなっているか」を必ず持つ（DESIGN.md I-5）。
/// 型として optional にしないため、この構造体自体を optional で持たせない。
public struct CurrentStateFacts: Equatable, Sendable {
    /// 切替元。単独起動では対象が存在しないため nil。
    public let source: ProjectFact?
    /// 切替先。単独停止では対象が存在しないため nil。
    public let target: ProjectFact?

    public init(source: ProjectFact?, target: ProjectFact?) {
        self.source = source
        self.target = target
    }

    /// 画面へそのまま出せる断言文。中途半端な状態を黙って伏せない。
    public var statements: [String] {
        [source?.statement, target?.statement].compactMap { $0 }
    }
}

public struct SwitchOutcome: Equatable, Sendable {
    public let facts: CurrentStateFacts
    /// `failurePolicy: continue` で落ちたサービス。一部停止として可視化する。
    public let degradedServices: [String]

    public init(facts: CurrentStateFacts, degradedServices: [String]) {
        self.facts = facts
        self.degradedServices = degradedServices
    }
}

/// 停止しきれなかったサービス。
///
/// 復旧手段（確認のうえでの強制終了）を UI が出せるよう、名前だけでなく
/// 対象を特定できる情報を持つ。ここを名前だけにすると、画面から復旧できなくなる。
public struct StopFailureDetail: Equatable, Sendable, Identifiable {
    public let serviceID: UUID
    public let serviceName: String
    public let processGroupID: pid_t?
    public let reason: String

    public var id: UUID { serviceID }

    public init(
        serviceID: UUID,
        serviceName: String,
        processGroupID: pid_t?,
        reason: String
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.processGroupID = processGroupID
        self.reason = reason
    }

    public var description: String {
        let group = processGroupID.map { "プロセスグループ \($0)" } ?? "プロセスグループ不明"
        return "\(serviceName)（\(group)）: \(reason)"
    }
}

public struct SwitchFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// ゲートの前段。停止操作そのものが完了しなかった。
        case stopFailed(services: [StopFailureDetail])
        /// ゲート。停止元の実測ポートが解放されなかった。
        case portsNotReleased(holders: [ResolvedPortHolder])
        /// 起動フェーズ。`failurePolicy: block` のサービスが起動できなかった。
        case startFailed(service: String, reason: String)
        /// 起動フェーズ前の中止。切替元の停止は完了している。
        case cancelled
        /// MVP で実行できない設定。既定へ倒さず起動前に止める。
        case unsupportedConfiguration(String)
        /// ポートを実測できなかった。「空いている」と解釈せず、ここで止める。
        case portObservationFailed(context: String, reason: String)
        case operationInProgress

        public var title: String {
            switch self {
            case .stopFailed: "終了できない"
            case .portsNotReleased: "ポートが解放されない"
            case .startFailed: "起動直後に落ちた"
            case .cancelled: "切替を中止した"
            case .unsupportedConfiguration: "未対応の設定"
            case .portObservationFailed: "ポートを確認できない"
            case .operationInProgress: "処理が実行中"
            }
        }

        public var detail: String {
            switch self {
            case let .stopFailed(services):
                "停止しきれなかったサービス:\n"
                    + services.map(\.description).joined(separator: "\n")
            case let .portsNotReleased(holders):
                "解放されていないポート:\n"
                    + holders.map(\.description).joined(separator: "\n")
            case let .startFailed(service, reason):
                "サービス「\(service)」を起動できませんでした。\n\(reason)"
            case .cancelled:
                "切替元の停止は完了しました。切替先は起動していません。"
            case let .unsupportedConfiguration(message):
                message
            case let .portObservationFailed(context, reason):
                "\(context)に失敗しました。空いているとは判断できないため、起動を中止しました。\n\(reason)"
            case .operationInProgress:
                "ほかの切替処理が実行中です。完了してから操作してください。"
            }
        }
    }

    public let reason: Reason
    /// 失敗画面には必ず現在の状態を書く（I-5）。optional にしない。
    public let facts: CurrentStateFacts

    public init(reason: Reason, facts: CurrentStateFacts) {
        self.reason = reason
        self.facts = facts
    }

    public var description: String {
        ([reason.title, reason.detail] + facts.statements).joined(separator: "\n")
    }
}
