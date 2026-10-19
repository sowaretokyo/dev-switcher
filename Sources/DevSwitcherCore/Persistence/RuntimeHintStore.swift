import Darwin
import Foundation

/// アプリ再起動後の再検証に使う手掛かり。
///
/// これは「稼働中だった」という事実の記録ではない。次回起動時に実プロセスを観測し、
/// ここに書いてある錨と突き合わせるための照合材料でしかない。
/// 一致しなければ引き継がず、一致してもこの値を状態として復元しない。
/// プロジェクト定義（`projects.json`）とは別ファイルに置き、設定と混ざらないようにする。
public struct RuntimeHint: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let serviceID: UUID
    public let serviceName: String
    public let processGroupID: pid_t
    /// 起動または引き継いだプロセス本体。
    public let leader: ProcessAnchor
    /// 記録時点で生きていたグループメンバー全員の錨と、起動セッション。
    /// 本体が終了しても、ここに残る子孫を根拠にグループを同定する。
    public let groupEvidence: ProcessGroupEvidence
    /// 表示と原因調査に使う補助情報。安全性の根拠にはしない。
    public let executablePath: String
    public let workingDirectory: URL
    /// 記録時に実測した listen ポート。設定値ではない。
    /// 実測できなかった場合は `.unavailable` を保存する。空配列と混同しない。
    public let observedPorts: ObservedPortRecord

    public init(
        projectID: UUID,
        serviceID: UUID,
        serviceName: String,
        processGroupID: pid_t,
        leader: ProcessAnchor,
        groupEvidence: ProcessGroupEvidence,
        executablePath: String,
        workingDirectory: URL,
        observedPorts: ObservedPortRecord
    ) {
        self.projectID = projectID
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.processGroupID = processGroupID
        self.leader = leader
        self.groupEvidence = groupEvidence
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.observedPorts = observedPorts
    }

    public func updating(
        groupEvidence evidence: ProcessGroupEvidence,
        observedPorts: ObservedPortRecord? = nil
    ) -> RuntimeHint {
        RuntimeHint(
            projectID: projectID,
            serviceID: serviceID,
            serviceName: serviceName,
            processGroupID: processGroupID,
            leader: leader,
            groupEvidence: evidence,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            observedPorts: observedPorts ?? self.observedPorts
        )
    }

    public func updatingGroupEvidence(_ evidence: ProcessGroupEvidence) -> RuntimeHint {
        updating(groupEvidence: evidence)
    }
}

/// schema version 1 の手掛かり。
///
/// v1 は wall-clock の開始時刻しか持たない。これは時計の変更で前後するため、
/// そのままではプロセスグループ同定の根拠にできない。
/// 本体を今の実測で確認できた場合にだけ、その場で安定した錨を測り直して現行形式へ変換する。
/// 本体を確認できない v1 の記録からシグナルを送ってはいけない。
public struct LegacyRuntimeHint: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let serviceID: UUID
    public let serviceName: String
    public let pid: pid_t
    public let processGroupID: pid_t
    public let startTimeMicroseconds: UInt64
    public let executablePath: String
    public let workingDirectory: URL
    public let observedPorts: [Int]

    public init(
        projectID: UUID,
        serviceID: UUID,
        serviceName: String,
        pid: pid_t,
        processGroupID: pid_t,
        startTimeMicroseconds: UInt64,
        executablePath: String,
        workingDirectory: URL,
        observedPorts: [Int]
    ) {
        self.projectID = projectID
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.pid = pid
        self.processGroupID = processGroupID
        self.startTimeMicroseconds = startTimeMicroseconds
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.observedPorts = observedPorts
    }
}

/// PIDを持たない管理対象スタックを、次回起動時に再検証するための手掛かり（docs/ARCHITECTURE.md 6.2）。
///
/// 稼働状態そのものではなく、再検証すべき対象と、保存時のIDと構成同一性だけを保存する。
/// 保存値だけで稼働中へは戻さない（docs/SPEC.md 11、6.5）。
public struct ManagedStackHint: Codable, Equatable, Sendable {
    /// 開発環境のID。スタックのID（`identity`）とは別物。
    public let projectID: UUID
    /// v3 から移行したスタックは旧サービス ID と同じ。
    public let stackID: UUID
    public let stackName: String
    public let type: ManagedStackType
    /// 以下が nil なのは、旧 schema から移行した未検証の手掛かりだけ。3 つそろって nil になる。
    /// nil の手掛かりを根拠に状態確認や停止のコマンドを実行しない。
    public let identity: ManagedStackIdentity?
    public let fingerprint: ManagedStackFingerprint?
    public let relationship: ManagedStackRelationship?

    /// 管理下へ入ったスタックから手掛かりを作る。種類・ID・構成同一性は解決済みの設定から取り、食い違わない。
    public init(
        projectID: UUID,
        stackID: UUID,
        stackName: String,
        configuration: ResolvedStackConfiguration,
        relationship: ManagedStackRelationship
    ) {
        self.projectID = projectID
        self.stackID = stackID
        self.stackName = stackName
        type = configuration.type
        identity = configuration.identity
        fingerprint = configuration.fingerprint
        self.relationship = relationship
    }

    /// 解決済みのスタックから手掛かりを作る。
    public init(_ stack: ResolvedManagedStack, relationship: ManagedStackRelationship) {
        self.init(
            projectID: stack.environmentID,
            stackID: stack.stackID,
            stackName: stack.stackName,
            configuration: stack.configuration,
            relationship: relationship
        )
    }

    /// 旧schemaの手掛かりは、コマンド実行に必要なIDと構成同一性を持たない。
    /// 捨てずに保持し、利用者へ理由を出すためだけに使う。
    fileprivate init(
        unverified projectID: UUID,
        stackID: UUID,
        stackName: String,
        type: ManagedStackType
    ) {
        self.projectID = projectID
        self.stackID = stackID
        self.stackName = stackName
        self.type = type
        identity = nil
        fingerprint = nil
        relationship = nil
    }

    /// 管理関係があり、保存時のIDと構成同一性が現在の設定から解決した値と一致するか。
    /// 一致しなければ、この手掛かりを根拠に状態確認や停止のコマンドを実行しない。
    public func matches(_ resolved: ResolvedManagedStack) -> Bool {
        guard relationship != nil, let identity, let fingerprint else { return false }
        return identity == resolved.identity && fingerprint == resolved.fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case stackID
        case stackName
        case type
        case identity
        case fingerprint
        case relationship
    }

    /// 欠落値を既定値で補完しない。キーが無ければ移行漏れとして失敗させる。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        stackID = try container.decode(UUID.self, forKey: .stackID)
        stackName = try container.decode(String.self, forKey: .stackName)
        type = try container.decode(ManagedStackType.self, forKey: .type)
        for key in [CodingKeys.identity, .fingerprint, .relationship]
        where !container.contains(key) {
            throw DecodingError.keyNotFound(
                key,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "managed hintの\(key.stringValue)がありません。"
                )
            )
        }
        identity = try container.decodeIfPresent(ManagedStackIdentity.self, forKey: .identity)
        fingerprint = try container.decodeIfPresent(
            ManagedStackFingerprint.self,
            forKey: .fingerprint
        )
        relationship = try container.decodeIfPresent(
            ManagedStackRelationship.self,
            forKey: .relationship
        )

        // 未検証の手掛かりは 3 つそろって null。一部だけ欠けた記録は推測で補わない。
        let presence = [identity != nil, fingerprint != nil, relationship != nil]
        guard presence.allSatisfy({ $0 }) || presence.allSatisfy({ !$0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .relationship,
                in: container,
                debugDescription: "managed hintのidentity・fingerprint・relationshipは、すべて値を持つか、すべてnullである必要があります。"
            )
        }
        if let identity, identity.type != type {
            throw DecodingError.dataCorruptedError(
                forKey: .identity,
                in: container,
                debugDescription: "managed hintのidentityの種類（\(identity.type.rawValue)）がtype（\(type.rawValue)）と一致しません。"
            )
        }
        if let fingerprint, fingerprint.type != type {
            throw DecodingError.dataCorruptedError(
                forKey: .fingerprint,
                in: container,
                debugDescription: "managed hintのfingerprintの種類（\(fingerprint.type.rawValue)）がtype（\(type.rawValue)）と一致しません。"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(stackID, forKey: .stackID)
        try container.encode(stackName, forKey: .stackName)
        try container.encode(type, forKey: .type)
        // nilも明示的に書き出す。キーを落とすと、次回の読み込みで移行漏れと区別できない。
        try encodeOptional(identity, forKey: .identity, in: &container)
        try encodeOptional(fingerprint, forKey: .fingerprint, in: &container)
        try encodeOptional(relationship, forKey: .relationship, in: &container)
    }

    private func encodeOptional<Value: Encodable>(
        _ value: Value?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public struct RuntimeHintsDocument: Codable, Sendable {
    /// version 7 で、管理対象スタックの手掛かりを種類共通の形式（`ManagedStackHint`）にする。
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var hints: [RuntimeHint]
    /// まだ安全な形へ変換できていない旧形式の記録。停止には使わない。
    /// 変換できるまで捨てずに持ち回る。消すと残存プロセスを見失う。
    public var legacyHints: [LegacyRuntimeHint]
    public var managedHints: [ManagedStackHint]

    public init(
        schemaVersion: Int = RuntimeHintsDocument.currentSchemaVersion,
        hints: [RuntimeHint],
        legacyHints: [LegacyRuntimeHint] = [],
        managedHints: [ManagedStackHint] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hints = hints
        self.legacyHints = legacyHints
        self.managedHints = managedHints
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
        case managedHints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hints = try container.decode([RuntimeHint].self, forKey: .hints)
        legacyHints = try container.decodeIfPresent(
            [LegacyRuntimeHint].self,
            forKey: .legacyHints
        ) ?? []
        // v3〜v6は専用の移行分岐で読む。現行v7でこのキーが欠けている場合は、
        // 稼働中スタックの手掛かりを空配列として失わずdecodeを失敗させる。
        managedHints = try container.decode([ManagedStackHint].self, forKey: .managedHints)
    }
}

/// schema version 6 のmanaged hint。Supabase専用で、種類を持たない。
/// 過去の形を固定して読み込み専用で残し、`ManagedStackHint`へ変換する。
private struct ManagedRuntimeHint: Decodable {
    let projectID: UUID
    let serviceID: UUID
    let serviceName: String
    /// nilは旧schemaから移行した未検証の手掛かりだけを表す。
    let supabaseProjectID: SupabaseProjectID?
    let configDirectory: URL?
    let fingerprint: SupabaseLifecycleFingerprint?
    let relationship: ManagedStackRelationship?

    private enum CodingKeys: String, CodingKey {
        case projectID
        case serviceID
        case serviceName
        case supabaseProjectID
        case configDirectory
        case fingerprint
        case relationship
    }

    /// 欠落値を既定値で補完しない。v6でキーが無ければ移行漏れとして失敗させる。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        serviceID = try container.decode(UUID.self, forKey: .serviceID)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        for key in [CodingKeys.supabaseProjectID, .configDirectory, .fingerprint, .relationship]
        where !container.contains(key) {
            throw DecodingError.keyNotFound(
                key,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "managed hintの\(key.stringValue)がありません。"
                )
            )
        }
        supabaseProjectID = try container.decodeIfPresent(
            SupabaseProjectID.self,
            forKey: .supabaseProjectID
        )
        configDirectory = try container.decodeIfPresent(URL.self, forKey: .configDirectory)
        fingerprint = try container.decodeIfPresent(
            SupabaseLifecycleFingerprint.self,
            forKey: .fingerprint
        )
        relationship = try container.decodeIfPresent(
            ManagedStackRelationship.self,
            forKey: .relationship
        )
    }

    /// v7 の形へ変換する。値がそろわない、または設定ディレクトリが構成同一性と食い違う記録は、
    /// 照合できないので未検証の手掛かりとして持ち回る。ファイル全体は失敗させない。
    var migrated: ManagedStackHint {
        guard let supabaseProjectID,
              let configDirectory,
              let fingerprint,
              let relationship,
              configDirectory == fingerprint.configDirectory else {
            return ManagedStackHint(
                unverified: projectID,
                stackID: serviceID,
                stackName: serviceName,
                type: .supabase
            )
        }
        return ManagedStackHint(
            projectID: projectID,
            stackID: serviceID,
            stackName: serviceName,
            type: .supabase,
            identity: ManagedStackIdentity(supabaseProjectID),
            fingerprint: .supabase(fingerprint),
            relationship: relationship
        )
    }
}

private extension ManagedStackHint {
    /// 旧 schema の値から作る。種類・ID・構成同一性の整合は呼び出し側が保証する。
    init(
        projectID: UUID,
        stackID: UUID,
        stackName: String,
        type: ManagedStackType,
        identity: ManagedStackIdentity,
        fingerprint: ManagedStackFingerprint,
        relationship: ManagedStackRelationship
    ) {
        self.projectID = projectID
        self.stackID = stackID
        self.stackName = stackName
        self.type = type
        self.identity = identity
        self.fingerprint = fingerprint
        self.relationship = relationship
    }
}

private struct RuntimeHintsDocumentV6: Decodable {
    let schemaVersion: Int
    let hints: [RuntimeHint]
    let legacyHints: [LegacyRuntimeHint]
    let managedHints: [ManagedRuntimeHint]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
        case managedHints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hints = try container.decode([RuntimeHint].self, forKey: .hints)
        legacyHints = try container.decodeIfPresent(
            [LegacyRuntimeHint].self,
            forKey: .legacyHints
        ) ?? []
        // 稼働中Supabaseの手掛かりを空配列として失わない。
        managedHints = try container.decode([ManagedRuntimeHint].self, forKey: .managedHints)
    }
}

/// schema version 4/5のmanaged hint。`project_id`と管理関係を持たないため、
/// 移行後も未検証のまま保持し、status/stopには使わない。
private struct LegacyManagedHintIdentity: Decodable {
    let projectID: UUID
    let serviceID: UUID
    let serviceName: String

    /// 構成同一性が無いので、再検証もstatus/stopもできない手掛かりとして持ち回る。
    /// v4・v5 の管理対象はSupabaseだけだった。
    var unverifiedHint: ManagedStackHint {
        ManagedStackHint(
            unverified: projectID,
            stackID: serviceID,
            stackName: serviceName,
            type: .supabase
        )
    }
}

/// schema version 4・5 のドキュメント。両バージョンの形は同じ。
private struct RuntimeHintsDocumentV4V5: Decodable {
    let schemaVersion: Int
    let hints: [RuntimeHint]
    let legacyHints: [LegacyRuntimeHint]
    let managedHints: [LegacyManagedHintIdentity]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
        case managedHints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hints = try container.decode([RuntimeHint].self, forKey: .hints)
        legacyHints = try container.decodeIfPresent(
            [LegacyRuntimeHint].self,
            forKey: .legacyHints
        ) ?? []
        managedHints = try container.decode([LegacyManagedHintIdentity].self, forKey: .managedHints)
    }
}

/// schema version 3 のドキュメント。managed commandの手掛かりはまだ無い。
struct RuntimeHintsDocumentV3: Decodable {
    let schemaVersion: Int
    let hints: [RuntimeHint]
    let legacyHints: [LegacyRuntimeHint]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hints = try container.decode([RuntimeHint].self, forKey: .hints)
        legacyHints = try container.decodeIfPresent(
            [LegacyRuntimeHint].self,
            forKey: .legacyHints
        ) ?? []
    }
}

/// schema version 2 のhint。当時の `observedPorts` は整数配列だった。
/// 現行enumで直接decodeすると既存v2ファイルを読めないため、過去の形を固定して残す。
struct RuntimeHintV2: Decodable {
    let projectID: UUID
    let serviceID: UUID
    let serviceName: String
    let processGroupID: pid_t
    let leader: ProcessAnchor
    let groupEvidence: ProcessGroupEvidence
    let executablePath: String
    let workingDirectory: URL
    let observedPorts: [Int]

    func migrated() -> RuntimeHint {
        RuntimeHint(
            projectID: projectID,
            serviceID: serviceID,
            serviceName: serviceName,
            processGroupID: processGroupID,
            leader: leader,
            groupEvidence: groupEvidence,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            observedPorts: .observed(observedPorts)
        )
    }
}

struct RuntimeHintsDocumentV2: Decodable {
    let schemaVersion: Int
    let hints: [RuntimeHintV2]
    let legacyHints: [LegacyRuntimeHint]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hints = try container.decode([RuntimeHintV2].self, forKey: .hints)
        legacyHints = try container.decodeIfPresent(
            [LegacyRuntimeHint].self,
            forKey: .legacyHints
        ) ?? []
    }
}

/// schema version 1 のドキュメント。当時の形のまま読む。
struct RuntimeHintsDocumentV1: Decodable {
    let schemaVersion: Int
    let hints: [LegacyRuntimeHint]
}

/// 読み込み結果。旧形式は別に返す。現行形式と混ぜると、
/// 安全でない記録から停止操作へ進む経路ができる。
public struct RuntimeHintsLoad: Equatable, Sendable {
    public let hints: [RuntimeHint]
    public let legacy: [LegacyRuntimeHint]
    public let managed: [ManagedStackHint]

    public init(
        hints: [RuntimeHint],
        legacy: [LegacyRuntimeHint] = [],
        managed: [ManagedStackHint] = []
    ) {
        self.hints = hints
        self.legacy = legacy
        self.managed = managed
    }

    public var isEmpty: Bool { hints.isEmpty && legacy.isEmpty && managed.isEmpty }
}

public enum RuntimeHintStoreError: Error, Sendable, CustomStringConvertible {
    case decodingFailed(path: String, reason: String)
    case duplicateServiceID(UUID)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .decodingFailed(path, reason):
            "再検証の手掛かりを読み込めませんでした（\(path)）。\n\(reason)"
        case let .duplicateServiceID(serviceID):
            "再検証の手掛かりでサービス ID が重複しています（\(serviceID.uuidString)）。"
        case let .unsupportedSchemaVersion(found, supported):
            "再検証の手掛かりのスキーマバージョン \(found) は未対応です（対応バージョン: \(supported)）。"
        case let .writeFailed(path, reason):
            "再検証の手掛かりを保存できませんでした（\(path)）。\n\(reason)"
        }
    }
}

/// 手掛かりの読み書き。
///
/// 保存失敗の順序（起動前・起動後・停止後）は安全性の中心なので、
/// ファイル権限や実行ユーザーに頼らず決定的に検証できるようにここで境界を切る。
/// 実体は `RuntimeHintStore` ひとつで、外部依存は増やさない。
public protocol RuntimeHintPersisting: Sendable {
    func load() throws -> RuntimeHintsLoad
    func save(
        _ hints: [RuntimeHint],
        legacy: [LegacyRuntimeHint],
        managed: [ManagedStackHint]
    ) throws
}

public struct RuntimeHintStore: RuntimeHintPersisting, Sendable {
    public static let fileName = "runtime-hints.json"

    public let directory: URL

    public var fileURL: URL {
        directory.appendingPathComponent(RuntimeHintStore.fileName, isDirectory: false)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultStore() throws -> RuntimeHintStore {
        RuntimeHintStore(directory: try ApplicationPaths.applicationSupportDirectory())
    }

    public func load() throws -> RuntimeHintsLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RuntimeHintsLoad(hints: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RuntimeHintStoreError.decodingFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
        } catch {
            throw RuntimeHintStoreError.decodingFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }

        switch version {
        case RuntimeHintsDocument.currentSchemaVersion:
            return try decodeValidated(RuntimeHintsDocument.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(
                    hints: document.hints,
                    legacy: document.legacyHints,
                    managed: document.managedHints
                )
            }
        case 6:
            return try decodeValidated(RuntimeHintsDocumentV6.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(
                    hints: document.hints,
                    legacy: document.legacyHints,
                    managed: document.managedHints.map(\.migrated)
                )
            }
        case 4, 5:
            return try decodeValidated(RuntimeHintsDocumentV4V5.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(
                    hints: document.hints,
                    legacy: document.legacyHints,
                    managed: document.managedHints.map(\.unverifiedHint)
                )
            }
        case 3:
            return try decodeValidated(RuntimeHintsDocumentV3.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(hints: document.hints, legacy: document.legacyHints)
            }
        case 2:
            return try decodeValidated(RuntimeHintsDocumentV2.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(
                    hints: document.hints.map { $0.migrated() },
                    legacy: document.legacyHints
                )
            }
        case 1:
            // v1 の wall-clock 情報を、そのまま安全な錨へ変換しない。
            // 本体を実測で確認できたものだけを、あとから変換する。
            return try decodeValidated(RuntimeHintsDocumentV1.self, from: data, using: decoder) { document in
                RuntimeHintsLoad(hints: [], legacy: document.hints)
            }
        default:
            throw RuntimeHintStoreError.unsupportedSchemaVersion(
                found: version,
                supported: RuntimeHintsDocument.currentSchemaVersion
            )
        }
    }

    /// 1 バージョン分の文書を decode し、現在の形へ変換して検証する。
    /// 検証エラー（`RuntimeHintStoreError`）はそのまま、それ以外の失敗は`decodingFailed`として throw する。
    private func decodeValidated<Document: Decodable>(
        _ type: Document.Type,
        from data: Data,
        using decoder: JSONDecoder,
        _ convert: (Document) -> RuntimeHintsLoad
    ) throws -> RuntimeHintsLoad {
        do {
            let document = try decoder.decode(type, from: data)
            return try validated(convert(document))
        } catch let error as RuntimeHintStoreError {
            throw error
        } catch {
            throw RuntimeHintStoreError.decodingFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }
    }

    public func save(
        _ hints: [RuntimeHint],
        legacy: [LegacyRuntimeHint] = [],
        managed: [ManagedStackHint] = []
    ) throws {
        _ = try validated(RuntimeHintsLoad(hints: hints, legacy: legacy, managed: managed))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(
                RuntimeHintsDocument(
                    hints: hints,
                    legacyHints: legacy,
                    managedHints: managed
                )
            )
        } catch {
            throw RuntimeHintStoreError.writeFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RuntimeHintStoreError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    public func clear() throws {
        try save([], legacy: [], managed: [])
    }

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// AppStateがDictionary化する前に重複を拒否し、後勝ちの上書きを発生させない。
    /// 管理対象スタックのIDは、通常の手掛かりのサービスIDと横断して重複を確かめる。
    private func validated(_ load: RuntimeHintsLoad) throws -> RuntimeHintsLoad {
        var serviceIDs: Set<UUID> = []
        for serviceID in load.hints.map(\.serviceID)
            + load.legacy.map(\.serviceID)
            + load.managed.map(\.stackID) {
            guard serviceIDs.insert(serviceID).inserted else {
                throw RuntimeHintStoreError.duplicateServiceID(serviceID)
            }
        }
        return load
    }
}
