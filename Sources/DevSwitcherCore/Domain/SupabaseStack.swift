import Foundation

/// ローカルSupabaseスタックの同一性。
///
/// Supabase CLIが同一マシン上のローカルプロジェクトを区別する値（`supabase/config.toml`の
/// `project_id`）だけを根拠にする。ディレクトリ名、コンテナ名、ポートからは補完しない。
public struct SupabaseProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Dockerのコンテナ名へ使える文字だけを受け付ける。
    /// `-`始まりを弾くのは、`--project-id`の値がフラグとして解釈されないようにするため。
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              let first = trimmed.first,
              first.isLetter || first.isNumber,
              trimmed.allSatisfy({ Self.allowedCharacters.contains($0) }) else {
            return nil
        }
        self.rawValue = trimmed
    }

    private static let allowedCharacters: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
    )

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = SupabaseProjectID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "project_id「\(raw)」を解釈できません。"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// スタックの実測状態（`MVP_SPEC.md` 5.5）。
/// 観測できないことを「停止中」へ倒さないため、`unknown`を独立させる。
public enum SupabaseStackState: String, Equatable, Sendable {
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

/// 管理関係（`MVP_SPEC.md` 5.5）。状態とは別に持ち、停止権限の根拠にする。
public enum SupabaseManagementRelationship: String, Equatable, Sendable, Codable {
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
public struct SupabaseStackObservation: Equatable, Sendable {
    public let projectID: SupabaseProjectID
    public let state: SupabaseStackState
    public let detail: String?

    public init(projectID: SupabaseProjectID, state: SupabaseStackState, detail: String? = nil) {
        self.projectID = projectID
        self.state = state
        self.detail = detail
    }

    /// 承認内容の同一判定は`project_id`と状態だけで行う。
    /// 判定根拠の文言差で再確認を出すと、利用者が理由なく操作を繰り返すことになる。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.state == rhs.state
    }
}

/// 観測時点のスタック集合。承認snapshotの照合にも使う。
public struct SupabaseStackSnapshot: Equatable, Sendable {
    /// 観測に成功した場合だけ、一覧にないIDを`notRunning`と判断できる。
    public let observations: [SupabaseStackObservation]
    public let inventoryFailure: String?

    public init(_ observations: [SupabaseStackObservation]) {
        self.observations = observations.sorted { $0.projectID.rawValue < $1.projectID.rawValue }
        inventoryFailure = nil
    }

    public init(unobservable reason: String) {
        observations = []
        inventoryFailure = reason
    }

    public func observation(of projectID: SupabaseProjectID) -> SupabaseStackObservation {
        if let inventoryFailure {
            return SupabaseStackObservation(projectID: projectID, state: .unknown, detail: inventoryFailure)
        }
        return observations.first { $0.projectID == projectID }
            ?? SupabaseStackObservation(projectID: projectID, state: .notRunning)
    }

    public func state(of projectID: SupabaseProjectID) -> SupabaseStackState {
        observation(of: projectID).state
    }

    public var unknownObservations: [SupabaseStackObservation] {
        observations.filter { $0.state == .unknown }
    }

    public var hasUnknown: Bool { inventoryFailure != nil || !unknownObservations.isEmpty }

    public var failureDetails: [String] {
        if let inventoryFailure { return [inventoryFailure] }
        return unknownObservations.map {
            "\($0.projectID): \($0.detail ?? "理由を取得できませんでした。")"
        }
    }
}

/// 確認シートへ出す1行。`project_id`は必須表示、登録の有無も明示する。
public struct SupabaseConfirmationTarget: Equatable, Sendable, Identifiable {
    public enum Action: String, Equatable, Sendable {
        /// 既存の同一スタックを引き継ぐ。`supabase start`は実行しない。
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
        public let projectName: String
        public let serviceName: String
        public let configDirectory: URL

        public init(projectName: String, serviceName: String, configDirectory: URL) {
            self.projectName = projectName
            self.serviceName = serviceName
            self.configDirectory = configDirectory
        }
    }

    public let projectID: SupabaseProjectID
    public let state: SupabaseStackState
    public let action: Action
    public let registration: Registration?

    public var id: String { projectID.rawValue }

    public init(
        projectID: SupabaseProjectID,
        state: SupabaseStackState,
        action: Action,
        registration: Registration?
    ) {
        self.projectID = projectID
        self.state = state
        self.action = action
        self.registration = registration
    }

    public var registrationLabel: String {
        guard let registration else { return "未登録" }
        return "\(registration.projectName) / \(registration.serviceName)"
    }
}

/// 起動・切替の直前に作る、Supabaseの処理計画。
/// 確認が要るかどうかも含めてここで決め、UIは表示と承認だけを担当する。
public struct SupabaseConfirmationPlan: Equatable, Sendable {
    public let serviceID: UUID
    public let serviceName: String
    public let projectName: String
    public let target: SupabaseConfirmationTarget
    /// 別`project_id`の停止対象。複数でも1つの確認にまとめる。
    public let stopTargets: [SupabaseConfirmationTarget]
    /// 確認時点の全スタックと状態。
    public let snapshot: SupabaseStackSnapshot
    /// 対象設定の同一性。承認後に設定が変わっていたら実行しない。
    public let fingerprint: SupabaseLifecycleFingerprint

    public init(
        serviceID: UUID,
        serviceName: String,
        projectName: String,
        target: SupabaseConfirmationTarget,
        stopTargets: [SupabaseConfirmationTarget],
        snapshot: SupabaseStackSnapshot,
        fingerprint: SupabaseLifecycleFingerprint
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.projectName = projectName
        self.target = target
        self.stopTargets = stopTargets
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }

    /// 対象を新規に起動するだけで、他スタックへ触れないなら確認を出さない。
    public var requiresConfirmation: Bool {
        target.action != .start || !stopTargets.isEmpty
    }

    public var allTargets: [SupabaseConfirmationTarget] { [target] + stopTargets }

    /// 利用者が承認した内容を、実行直前の照合に使える形で切り出す。
    public var approval: SupabaseApproval {
        SupabaseApproval(
            serviceID: serviceID,
            projectID: target.projectID,
            action: target.action,
            stopProjectIDs: stopTargets.map(\.projectID),
            snapshot: snapshot,
            fingerprint: fingerprint
        )
    }
}

/// 利用者の承認。確認時の全スタックIDと状態、対象設定のfingerprintを含める。
public struct SupabaseApproval: Equatable, Sendable {
    public let serviceID: UUID
    public let projectID: SupabaseProjectID
    public let action: SupabaseConfirmationTarget.Action
    public let stopProjectIDs: [SupabaseProjectID]
    public let snapshot: SupabaseStackSnapshot
    public let fingerprint: SupabaseLifecycleFingerprint

    public init(
        serviceID: UUID,
        projectID: SupabaseProjectID,
        action: SupabaseConfirmationTarget.Action,
        stopProjectIDs: [SupabaseProjectID],
        snapshot: SupabaseStackSnapshot,
        fingerprint: SupabaseLifecycleFingerprint
    ) {
        self.serviceID = serviceID
        self.projectID = projectID
        self.action = action
        self.stopProjectIDs = stopProjectIDs
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }
}

/// 対象設定が保存時・確認時から変わっていないかを、ハッシュ衝突なしで照合する値。
public struct SupabaseLifecycleFingerprint: Codable, Equatable, Sendable {
    public let executable: String
    public let startArguments: [String]
    public let startWorkingDirectory: URL
    public let configDirectory: URL

    public init(start: CommandSpec, configDirectory: URL) {
        executable = start.executable
        startArguments = start.arguments
        startWorkingDirectory = start.workingDirectory.standardizedFileURL
        self.configDirectory = configDirectory.standardizedFileURL
    }

    public var displayCommandLine: String {
        ([executable] + startArguments).joined(separator: " ")
    }
}
