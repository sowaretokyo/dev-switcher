import Foundation

// 管理対象スタックの状態・管理関係・観測・snapshot・確認 plan・承認（docs/ARCHITECTURE.md 4.1、4.3）。

/// スタックの実測状態（docs/SPEC.md 6.2）。
/// 観測できないことを「停止中」へ倒さないため、`unknown`を独立させる。
public enum ManagedStackState: String, Equatable, Sendable {
    case notRunning
    case running
    case degraded
    case unknown

    public var label: String {
        switch self {
        case .notRunning: "停止中"
        case .running: "稼働中"
        case .degraded: "一部だけ稼働"
        case .unknown: "判定不能"
        }
    }
}

/// 管理関係（docs/SPEC.md 6.2）。状態とは別に持ち、停止権限の根拠にする。
public enum ManagedStackRelationship: String, Equatable, Sendable, Codable {
    /// 今回Dev Switcherが起動した。
    case launched
    /// 外部で起動された同一スタックを、利用者の承認後に引き継いだ。
    case adopted
    /// 前回の`launched`または`adopted`を示す手掛かりを再検証できた。
    case restored

    public var label: String {
        switch self {
        case .launched: "今回起動"
        case .adopted: "引き継ぎ"
        case .restored: "再検証済み"
        }
    }
}

/// 1スタック分の実測結果。判定根拠は表示用に持ち、状態の同一判定には使わない。
public struct ManagedStackObservation: Equatable, Sendable {
    public let identity: ManagedStackIdentity
    public let state: ManagedStackState
    public let detail: String?

    public init(identity: ManagedStackIdentity, state: ManagedStackState, detail: String? = nil) {
        self.identity = identity
        self.state = state
        self.detail = detail
    }

    /// 承認内容の同一判定はIDと状態だけで行う。
    /// 判定根拠の文言差で再確認を出すと、利用者が理由なく操作を繰り返すことになる。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.state == rhs.state
    }
}

/// 観測時点のスタック集合。承認snapshotの照合にも使う。
///
/// 種類ごとに「観測済み」「観測失敗」「未観測」を区別する。観測に成功した種類だけ、
/// 一覧にないIDを`notRunning`と判断できる。
public struct ManagedStackSnapshot: Equatable, Sendable {
    public enum TypeResult: Equatable, Sendable {
        /// 観測に成功した。一覧は(type, value)昇順。
        case observed([ManagedStackObservation])
        /// 観測全体が失敗した。
        case failed(String)
    }

    /// 結果を持たない種類は未観測。
    public let results: [ManagedStackType: TypeResult]

    /// どの種類も未観測。
    public init() {
        results = [:]
    }

    /// 1種類の観測に成功した。`observations`は全件が`type`の種類であること。
    public init(type: ManagedStackType, observations: [ManagedStackObservation]) {
        precondition(
            observations.allSatisfy { $0.identity.type == type },
            "\(type.rawValue) の snapshot に別の種類の観測が含まれています。"
        )
        results = [type: .observed(observations.sorted { $0.identity < $1.identity })]
    }

    /// 1種類の観測全体が失敗した。
    public init(type: ManagedStackType, unobservable reason: String) {
        results = [type: .failed(reason)]
    }

    private init(results: [ManagedStackType: TypeResult]) {
        self.results = results
    }

    /// 別の種類の観測結果を合わせる。同じ種類を二重に持たせない。
    public func merging(_ other: ManagedStackSnapshot) -> ManagedStackSnapshot {
        precondition(
            Set(results.keys).isDisjoint(with: other.results.keys),
            "同じ種類の観測結果を二重に合わせようとしています。"
        )
        return ManagedStackSnapshot(results: results.merging(other.results) { current, _ in current })
    }

    private var sortedTypes: [ManagedStackType] {
        results.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// 観測に成功した種類の全観測。(type, value)昇順。
    public var observations: [ManagedStackObservation] {
        sortedTypes.flatMap { type -> [ManagedStackObservation] in
            guard case let .observed(observations) = results[type] else { return [] }
            return observations
        }
    }

    /// その種類の観測結果（成功・失敗を問わない）を持っているか。
    /// 観測失敗の結果も含む。一覧に無い ID を notRunning と判断する根拠には使わない。
    public func hasResult(for type: ManagedStackType) -> Bool {
        results[type] != nil
    }

    /// 観測全体が失敗した種類なら、その理由。
    public func failure(of type: ManagedStackType) -> String? {
        guard case let .failed(reason) = results[type] else { return nil }
        return reason
    }

    public func observation(of identity: ManagedStackIdentity) -> ManagedStackObservation {
        switch results[identity.type] {
        case let .observed(observations):
            return observations.first { $0.identity == identity }
                ?? ManagedStackObservation(identity: identity, state: .notRunning)
        case let .failed(reason):
            return ManagedStackObservation(identity: identity, state: .unknown, detail: reason)
        case nil:
            return ManagedStackObservation(
                identity: identity,
                state: .unknown,
                detail: Self.unobservedDetail(identity.type)
            )
        }
    }

    public func state(of identity: ManagedStackIdentity) -> ManagedStackState {
        observation(of: identity).state
    }

    /// 観測全体が失敗した、または観測に`unknown`を含む種類。rawValue 昇順。
    /// 未観測の種類は含めない。観測を試みて判定できなかったものだけを数える。
    var typesWithUnknown: [ManagedStackType] {
        sortedTypes.filter { type in
            switch results[type] {
            case .failed: true
            case let .observed(observations): observations.contains { $0.state == .unknown }
            case nil: false
            }
        }
    }

    /// 未観測の種類は含めない。観測を試みて判定できなかったものだけを数える。
    public var hasUnknown: Bool {
        !typesWithUnknown.isEmpty
    }

    /// 未観測の種類は含めない。
    public var failureDetails: [String] {
        sortedTypes.flatMap { type -> [String] in
            switch results[type] {
            case let .failed(reason):
                return [reason]
            case let .observed(observations):
                return observations.filter { $0.state == .unknown }.map {
                    "\($0.identity): \($0.detail ?? "理由を取得できませんでした。")"
                }
            case nil:
                return []
            }
        }
    }

    public static func unobservedDetail(_ type: ManagedStackType) -> String {
        "\(type.displayName)の状態をまだ観測できていません。"
    }
}

/// 確認シートへ出す1行。種類とIDは必須表示、登録の有無も明示する。
public struct ManagedStackConfirmationTarget: Equatable, Sendable, Identifiable {
    public enum Action: String, Equatable, Sendable {
        /// 既存の同一スタックを引き継ぐ。起動コマンドは実行しない。
        case adopt
        /// 対象限定stop → `notRunning`確認 → start → `running`確認。
        case restart
        /// 別スタックを停止する。
        case stop
        /// 対象を新しく起動する。
        case start

        public var label: String {
            switch self {
            case .adopt: "引き継ぐ"
            case .restart: "停止して起動し直す"
            case .stop: "停止する"
            case .start: "起動する"
            }
        }
    }

    /// 登録済み開発環境の情報。未登録なら nil。
    public struct Registration: Equatable, Sendable {
        public let environmentName: String
        public let stackName: String
        public let directory: URL

        public init(environmentName: String, stackName: String, directory: URL) {
            self.environmentName = environmentName
            self.stackName = stackName
            self.directory = directory
        }
    }

    /// 登録済みスタックのID。未登録のスタックは nil。
    public let stackID: UUID?
    public let identity: ManagedStackIdentity
    public let state: ManagedStackState
    public let action: Action
    public let registration: Registration?

    public var id: String { "\(identity.type.rawValue):\(identity.value)" }

    public init(
        stackID: UUID?,
        identity: ManagedStackIdentity,
        state: ManagedStackState,
        action: Action,
        registration: Registration?
    ) {
        self.stackID = stackID
        self.identity = identity
        self.state = state
        self.action = action
        self.registration = registration
    }

    public var registrationLabel: String {
        guard let registration else { return "未登録" }
        return "\(registration.environmentName) / \(registration.stackName)"
    }
}

/// 起動・切替の直前に作る、管理対象スタックの処理計画。
/// 確認が要るかどうかも含めてここで決め、UIは表示と承認だけを担当する。
public struct ManagedStackConfirmationPlan: Equatable, Sendable {
    public let environmentName: String
    /// 起動先の全スタックの行と、停止対象の行。
    public let entries: [ManagedStackConfirmationTarget]
    /// 確認時点の全観測。
    public let snapshot: ManagedStackSnapshot
    /// 起動先スタックごとの構成同一性。承認後に設定が変わっていたら実行しない。
    public let fingerprints: [UUID: ManagedStackFingerprint]

    public init(
        environmentName: String,
        entries: [ManagedStackConfirmationTarget],
        snapshot: ManagedStackSnapshot,
        fingerprints: [UUID: ManagedStackFingerprint]
    ) {
        guard let first = entries.first else {
            preconditionFailure("確認 plan に行がありません。")
        }
        precondition(first.stackID != nil, "確認 plan の先頭行(起動先)に stackID がありません。")
        precondition(first.registration != nil, "確認 plan の先頭行(起動先)に registration がありません。")
        self.environmentName = environmentName
        self.entries = entries
        self.snapshot = snapshot
        self.fingerprints = fingerprints
    }

    /// 全行が新規起動だけで、他スタックへ触れないなら確認を出さない。
    public var requiresConfirmation: Bool {
        entries.contains { $0.action != .start }
    }

    /// 利用者が承認した内容を、実行直前の照合に使える形で切り出す。
    public var approval: ManagedStackApproval {
        ManagedStackApproval(
            entries: entries.map {
                ManagedStackApproval.Entry(stackID: $0.stackID, identity: $0.identity, action: $0.action)
            },
            snapshot: snapshot,
            fingerprints: fingerprints
        )
    }
}

/// 利用者の承認。確認時の全スタックIDと状態、対象設定の構成同一性を含める。
/// 登録情報や表示用の文字列は照合に使わないため含めない。
public struct ManagedStackApproval: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let stackID: UUID?
        public let identity: ManagedStackIdentity
        public let action: ManagedStackConfirmationTarget.Action

        init(
            stackID: UUID?,
            identity: ManagedStackIdentity,
            action: ManagedStackConfirmationTarget.Action
        ) {
            self.stackID = stackID
            self.identity = identity
            self.action = action
        }
    }

    public let entries: [Entry]
    public let snapshot: ManagedStackSnapshot
    public let fingerprints: [UUID: ManagedStackFingerprint]

    public init(
        entries: [Entry],
        snapshot: ManagedStackSnapshot,
        fingerprints: [UUID: ManagedStackFingerprint]
    ) {
        self.entries = entries
        self.snapshot = snapshot
        self.fingerprints = fingerprints
    }
}
