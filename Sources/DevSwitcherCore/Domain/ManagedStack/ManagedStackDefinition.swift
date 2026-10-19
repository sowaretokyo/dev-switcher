import Foundation

// 管理対象スタックの種類に依存しない定義（docs/ARCHITECTURE.md 4.1）。
// 公開型の署名には種類固有の型を出さない。種類固有の値は enum の関連値として包む。

/// 管理対象スタックの種類。
public enum ManagedStackType: String, Codable, Sendable, CaseIterable {
    case supabase

    /// 種類ごとの契約のうち、設定検証と確認フローが参照する静的な部分。
    public var policy: ManagedStackPolicy {
        switch self {
        case .supabase:
            ManagedStackPolicy(
                maximumPerEnvironment: 1,
                conflictScope: .allOfType,
                supportsAdoption: true
            )
        }
    }

    /// 利用者に見せる種類名。文言はこの値から組み立てる。
    public var displayName: String {
        switch self {
        case .supabase: "Supabase"
        }
    }

    /// 利用者に見せるIDの呼び名。
    public var identityLabel: String {
        switch self {
        case .supabase: "`project_id`"
        }
    }

    /// IDとして受け付ける値か。正規化で値が変わるものは受け付けない。
    func isValidIdentityValue(_ value: String) -> Bool {
        switch self {
        case .supabase: SupabaseStackConfiguration.isValidIdentityValue(value)
        }
    }
}

public struct ManagedStackPolicy: Equatable, Sendable {
    /// 1 開発環境あたりの上限。nil は制限なし。`enabled` にかかわらず数える。
    public let maximumPerEnvironment: Int?
    /// 起動時に停止を確認する既存スタックの範囲。
    public let conflictScope: ConflictScope
    public let supportsAdoption: Bool

    public enum ConflictScope: Equatable, Sendable {
        /// 同じ種類の全スタック（Supabase）。
        case allOfType
        /// 対象と同じ ID だけ。
        case identityOnly
    }

    init(maximumPerEnvironment: Int?, conflictScope: ConflictScope, supportsAdoption: Bool) {
        self.maximumPerEnvironment = maximumPerEnvironment
        self.conflictScope = conflictScope
        self.supportsAdoption = supportsAdoption
    }
}

public enum ManagedStackIdentityError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidValue(type: ManagedStackType, value: String)
    case typeMismatch(expected: ManagedStackType, actual: ManagedStackType)

    public var description: String {
        switch self {
        case let .invalidValue(type, value):
            "\(type.displayName)の\(type.identityLabel)「\(value)」を解釈できません。"
        case let .typeMismatch(expected, actual):
            "\(expected.displayName)のIDが必要ですが、\(actual.displayName)のIDが渡されました。"
        }
    }
}

/// 同じ種類の中での同一性。値の検証は種類ごとの規則が行い、生成後は正規化しない。
public struct ManagedStackIdentity: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let type: ManagedStackType
    public let value: String

    /// 種類ごとの規則で検証する。不正な値は補正せず throw する。
    public init(type: ManagedStackType, value: String) throws {
        guard type.isValidIdentityValue(value) else {
            throw ManagedStackIdentityError.invalidValue(type: type, value: value)
        }
        self.type = type
        self.value = value
    }

    /// 種類ごとの検証済みの値から作る。呼び出し側が値の検証に責任を持つ。
    init(validatedType type: ManagedStackType, value: String) {
        self.type = type
        self.value = value
    }

    public var description: String { value }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.type.rawValue, lhs.value) < (rhs.type.rawValue, rhs.value)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ManagedStackType.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        do {
            try self.init(type: type, value: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "\(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(value, forKey: .value)
    }
}

/// 管理対象スタック 1 件の定義。Phase A では v3 の`kind: "supabase"`のサービスから作る。
public struct ManagedStackDefinition: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: ManagedStackConfiguration
    public var ports: [PortSpec]
    public var enabledByDefault: Bool
    public var failurePolicy: FailurePolicy

    public init(
        id: UUID,
        name: String,
        configuration: ManagedStackConfiguration,
        ports: [PortSpec],
        enabledByDefault: Bool,
        failurePolicy: FailurePolicy
    ) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.ports = ports
        self.enabledByDefault = enabledByDefault
        self.failurePolicy = failurePolicy
    }

    public var type: ManagedStackType { configuration.type }
}

/// 種類ごとの設定。
public enum ManagedStackConfiguration: Equatable, Sendable {
    case supabase(SupabaseStackConfiguration)

    public var type: ManagedStackType {
        switch self {
        case .supabase: .supabase
        }
    }

    /// ファイルを読まずに判定できる設定エラー（禁止オプション、起動コマンドの形式など）。
    public func structuralIssues(workingDirectory: URL) -> [ManagedStackConfigurationIssue] {
        switch self {
        case let .supabase(configuration):
            configuration.structuralIssues(workingDirectory: workingDirectory).map { .supabase($0) }
        }
    }

    /// ファイルを読まずに導出できる設定。設定が不正なら nil。
    public func derived(workingDirectory: URL) -> ManagedStackDerivedConfiguration? {
        switch self {
        case let .supabase(configuration):
            configuration.derived(workingDirectory: workingDirectory).map { .supabase($0) }
        }
    }

    /// 設定ファイルを読んで ID を決める。推測で補わず、決められなければ throw する。
    /// 構造不備は`ManagedStackConfigurationError`、設定ファイルの読み取りエラーは種類ごとのエラーを
    /// ラップせずに throw する。
    public func resolve(workingDirectory: URL) throws -> ResolvedStackConfiguration {
        switch self {
        case let .supabase(configuration):
            .supabase(try configuration.resolve(workingDirectory: workingDirectory))
        }
    }
}

/// 種類ごとの導出済み設定。汎用型の署名に種類固有の型を直接出さないための包み。
public enum ManagedStackDerivedConfiguration: Equatable, Sendable {
    case supabase(SupabaseDerivedConfiguration)
}

/// ファイルを読まずに判定できる設定の不備。
public enum ManagedStackConfigurationIssue: Equatable, Sendable {
    case supabase(SupabaseConfigurationIssue)

    /// 起動・切替・手掛かりの再検証で示す理由。
    public var failureReason: String {
        switch self {
        case let .supabase(issue): issue.failureReason
        }
    }

    /// 保存・取り込み時の検証で示す文言。
    public func validationMessage(stackName: String) -> String {
        switch self {
        case let .supabase(issue): issue.validationMessage(stackName: stackName)
        }
    }
}

public enum ManagedStackConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 構造不備。description は`failureReason`と同一。
    case invalid(ManagedStackConfigurationIssue)

    public var description: String {
        switch self {
        case let .invalid(issue):
            issue.failureReason
        }
    }
}

/// ID と構成同一性まで確定した設定。コマンドはここからしか作れない。
public enum ResolvedStackConfiguration: Equatable, Sendable {
    case supabase(SupabaseResolvedConfiguration)

    public var type: ManagedStackType {
        switch self {
        case .supabase: .supabase
        }
    }

    public var identity: ManagedStackIdentity {
        switch self {
        case let .supabase(configuration): configuration.identity
        }
    }

    public var fingerprint: ManagedStackFingerprint {
        switch self {
        case let .supabase(configuration): .supabase(configuration.fingerprint)
        }
    }

    /// 確認シートの登録情報に出すディレクトリ。Supabase は`project_id`を読んだ設定ディレクトリ。
    public var registrationDirectory: URL {
        switch self {
        case let .supabase(configuration): configuration.derived.configDirectory
        }
    }
}

/// 確認時・保存時と設定が変わっていないかを、ハッシュではなく値の比較で照合する。
///
/// JSON は`{"type": "supabase", "supabase": {…}}`。`type`と中身の種類が合わなければ decode に失敗する。
public enum ManagedStackFingerprint: Codable, Equatable, Sendable {
    case supabase(SupabaseLifecycleFingerprint)

    public var type: ManagedStackType {
        switch self {
        case .supabase: .supabase
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case supabase
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ManagedStackType.self, forKey: .type)
        switch type {
        case .supabase:
            self = .supabase(
                try container.decode(SupabaseLifecycleFingerprint.self, forKey: .supabase)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .supabase(fingerprint):
            try container.encode(fingerprint, forKey: .supabase)
        }
    }
}

/// 開発環境に属するスタック 1 件の、ID まで確定した設定。
public struct ResolvedManagedStack: Equatable, Sendable {
    public let environmentID: UUID
    public let stackID: UUID
    public let stackName: String
    public let configuration: ResolvedStackConfiguration
    /// 解決元の設定。
    public let sourceConfiguration: ManagedStackConfiguration

    /// 設定ファイルを読んで解決する。
    public init(
        environmentID: UUID,
        definition: ManagedStackDefinition,
        workingDirectory: URL
    ) throws {
        self.init(
            environmentID: environmentID,
            stackID: definition.id,
            stackName: definition.name,
            configuration: try definition.configuration.resolve(workingDirectory: workingDirectory),
            sourceConfiguration: definition.configuration
        )
    }

    /// テストで設定ファイルを読まずに作るための口。
    init(
        environmentID: UUID,
        stackID: UUID,
        stackName: String,
        configuration: ResolvedStackConfiguration,
        sourceConfiguration: ManagedStackConfiguration
    ) {
        self.environmentID = environmentID
        self.stackID = stackID
        self.stackName = stackName
        self.configuration = configuration
        self.sourceConfiguration = sourceConfiguration
    }

    public var type: ManagedStackType { configuration.type }
    public var identity: ManagedStackIdentity { configuration.identity }
    public var fingerprint: ManagedStackFingerprint { configuration.fingerprint }
}
