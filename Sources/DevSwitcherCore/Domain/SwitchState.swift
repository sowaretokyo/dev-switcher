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

    /// 起動フェーズへ入ったか。入った後は中止を受け付けない（`docs/SPEC.md` 16.2 I-4）。
    public var hasEnteredStartPhase: Bool {
        switch self {
        case .starting, .observingStartup, .rollingBack, .completed: true
        case .idle, .stopping, .verifyingRelease: false
        }
    }

    public var label: String {
        switch self {
        case .idle: L10n.text("待機中")
        case let .stopping(service, index, total): L10n.text("\(service) を停止（\(index)/\(total)）")
        case let .verifyingRelease(released, total): L10n.text("停止元のポート解放を確認（\(released)/\(total)）")
        case let .starting(service, index, total): L10n.text("\(service) を起動（\(index)/\(total)）")
        case let .observingStartup(service): L10n.text("\(service) の起動を確認")
        case let .rollingBack(service): L10n.text("\(service) を停止（巻き戻し）")
        case .completed: L10n.text("完了")
        }
    }
}

/// ポートを握っているプロセスの所有区分。出せる操作を型から導く（`docs/SPEC.md` 12）。
public enum PortOwnership: Equatable, Sendable {
    /// Dev Switcher が起動または引き継いだプロセス。通常の自動停止対象。
    case ownedByUs(serviceID: UUID, serviceName: String)
    /// 同一利用者の外部プロセス。表示はするが、Dev Switcher から signal は送らない。
    case external
    /// 別利用者またはシステム管理下。終了操作を提供しない。
    case systemOwned

    public var label: String {
        switch self {
        case let .ownedByUs(_, serviceName): L10n.text("Dev Switcher（\(serviceName)）")
        case .external: L10n.text("外部プロセス")
        case .systemOwned: L10n.text("システムまたは別ユーザー")
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

/// 競合したポートを名指しするために、ポート単位で保持する（`docs/SPEC.md` 9）。
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
        let commandLabel = command ?? L10n.text("コマンド取得不能")
        return L10n.text(":\(port) — PID \(pid) \(commandLabel)（\(ownership.label)）")
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
    public let warnings: [String]

    public init(
        projectID: UUID,
        projectName: String,
        phase: ProjectPhase,
        services: [ServiceFact],
        warnings: [String] = []
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.phase = phase
        self.services = services
        self.warnings = warnings
    }

    /// 「shop-web は停止しました。」のように、いまどうなっているかを1行で断言する。
    public var statement: String {
        switch phase {
        case .stopped: L10n.text("「\(projectName)」は停止しました。")
        case .starting: L10n.text("「\(projectName)」は起動処理の途中です。")
        case .running: L10n.text("「\(projectName)」は起動済みです。")
        case let .degraded(stoppedServices):
            L10n.text("「\(projectName)」は一部停止です（停止中: \(stoppedServices.joined(separator: " / "))）。")
        case .stopping: L10n.text("「\(projectName)」は終了処理の途中です。")
        case .switching: L10n.text("「\(projectName)」は切替処理の途中です。")
        case let .failed(reason): L10n.text("「\(projectName)」は失敗しました（\(reason)）。")
        case .residual: L10n.text("「\(projectName)」に停止しきれていないプロセスが残っています。")
        }
    }
}

/// 失敗時に「両方のプロジェクトが今どうなっているか」を必ず持つ（`docs/SPEC.md` 16.2 I-5）。
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
        let group = processGroupID.map { L10n.text("プロセスグループ \($0)") } ?? L10n.text("プロセスグループ不明")
        return L10n.text("\(serviceName)（\(group)）: \(reason)")
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
        /// 既存の管理対象スタックの引き継ぎ・復旧・停止についての承認待ち。
        /// 承認前は既存スタック、切替元、切替先のいずれも変更していない。
        case managedStackConfirmationRequired(plan: ManagedStackConfirmationPlan)
        /// Dockerや各CLIから状態を確定できなかった。停止中へ倒さない。
        case managedStackObservationFailed(types: [ManagedStackType], details: [String])
        /// 承認済みの既存スタックを停止できなかった。停止済みのスタックは再起動しない。
        case managedStackStopFailed(
            identity: ManagedStackIdentity,
            reason: String,
            stopped: [String],
            remaining: [String]
        )
        /// ポートを実測できなかった。「空いている」と解釈せず、ここで止める。
        case portObservationFailed(context: String, reason: String)
        case operationInProgress

        /// 種類名を並べる。複数種類のときの文言は Phase B で決める。
        private static func displayNames(of types: [ManagedStackType]) -> String {
            types.map(\.displayName).joined(separator: "、")
        }

        public var title: String {
            switch self {
            case .stopFailed: L10n.text("停止できない")
            case .portsNotReleased: L10n.text("ポートが解放されない")
            case .startFailed: L10n.text("起動に失敗")
            case .cancelled: L10n.text("切替を中止した")
            case .unsupportedConfiguration: L10n.text("未対応の設定")
            case let .managedStackConfirmationRequired(plan): L10n.text("\(plan.primaryEntry.identity.type.displayName)の確認")
            case let .managedStackObservationFailed(types, _): L10n.text("\(Self.displayNames(of: types))の状態を確認できない")
            case let .managedStackStopFailed(identity, _, _, _): L10n.text("既存の\(identity.type.displayName)を停止できない")
            case .portObservationFailed: L10n.text("ポートを確認できない")
            case .operationInProgress: L10n.text("処理が実行中")
            }
        }

        public var detail: String {
            switch self {
            case let .stopFailed(services):
                L10n.text("停止しきれなかったサービス:\n")
                    + services.map(\.description).joined(separator: "\n")
            case let .portsNotReleased(holders):
                L10n.text("解放されていないポート:\n")
                    + holders.map(\.description).joined(separator: "\n")
            case let .startFailed(service, reason):
                L10n.text("サービス「\(service)」を起動できませんでした。\n\(reason)")
            case .cancelled:
                L10n.text("切替元の停止は完了しました。切替先は起動していません。")
            case let .unsupportedConfiguration(message):
                message
            case let .managedStackConfirmationRequired(plan):
                L10n.text("サービス「\(plan.primaryStackName)」の起動前に、既存の\(plan.primaryEntry.identity.type.displayName)スタックの扱いを確認してください。\n")
                    + plan.entries
                    .map { L10n.text("\($0.identity): \($0.state.label) → \($0.action.label)（\($0.registrationLabel)）") }
                    .joined(separator: "\n")
            case let .managedStackObservationFailed(types, details):
                L10n.text("\(Self.displayNames(of: types))スタックの状態を確定できませんでした。停止中とは判断できないため、変更操作へ進みません。\n")
                    + details.joined(separator: "\n")
            case let .managedStackStopFailed(identity, reason, stopped, remaining):
                L10n.text("""
                    既存の\(identity.type.displayName)「\(identity)」を停止できませんでした。\n\(reason)\n\
                    停止済み: \(stopped.isEmpty ? L10n.text("なし") : stopped.joined(separator: " / "))\n\
                    未処理: \(remaining.isEmpty ? L10n.text("なし") : remaining.joined(separator: " / "))\n\
                    停止済みのスタックは自動で再起動しません。
                    """)
            case let .portObservationFailed(context, reason):
                L10n.text("\(context)に失敗しました。空いているとは判断できないため、起動を中止しました。\n\(reason)")
            case .operationInProgress:
                L10n.text("ほかの切替処理が実行中です。完了してから操作してください。")
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

extension ManagedStackConfirmationPlan {
    /// 起動先スタックの行。`entries`の先頭で、確認 plan は必ず1行以上を持つ。
    /// Phase A の確認 plan は起動先 1 件、停止行の順に並ぶ。
    public var primaryEntry: ManagedStackConfirmationTarget {
        guard let first = entries.first else {
            preconditionFailure(L10n.text("確認 plan に行がありません。"))
        }
        return first
    }

    /// 起動先の行に続く、停止対象の行。
    public var stopEntries: [ManagedStackConfirmationTarget] {
        entries.filter { $0.action == .stop && $0.stackID == nil }
    }

    /// 起動先スタックの名前。先頭行の登録情報は plan の生成時に保証済み。
    public var primaryStackName: String {
        guard let registration = primaryEntry.registration else {
            preconditionFailure(L10n.text("確認 plan の先頭行に registration がありません。"))
        }
        return registration.stackName
    }
}
