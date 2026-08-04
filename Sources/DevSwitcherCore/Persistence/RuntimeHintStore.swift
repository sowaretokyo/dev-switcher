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

public struct RuntimeHintsDocument: Codable, Sendable {
    /// version 3 で、ポート観測不能を空配列と区別して保存する。
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var hints: [RuntimeHint]
    /// まだ安全な形へ変換できていない旧形式の記録。停止には使わない。
    /// 変換できるまで捨てずに持ち回る。消すと残存プロセスを見失う。
    public var legacyHints: [LegacyRuntimeHint]

    public init(
        schemaVersion: Int = RuntimeHintsDocument.currentSchemaVersion,
        hints: [RuntimeHint],
        legacyHints: [LegacyRuntimeHint] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hints = hints
        self.legacyHints = legacyHints
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hints
        case legacyHints
    }

    public init(from decoder: any Decoder) throws {
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

    public init(hints: [RuntimeHint], legacy: [LegacyRuntimeHint] = []) {
        self.hints = hints
        self.legacy = legacy
    }

    public var isEmpty: Bool { hints.isEmpty && legacy.isEmpty }
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
/// 保存失敗の順序（起動前・起動後・補償停止後）は安全性の中心なので、
/// ファイル権限や実行ユーザーに頼らず決定的に検証できるようにここで境界を切る。
/// 実体は `RuntimeHintStore` ひとつで、外部依存は増やさない。
public protocol RuntimeHintPersisting: Sendable {
    func load() throws -> RuntimeHintsLoad
    func save(_ hints: [RuntimeHint], legacy: [LegacyRuntimeHint]) throws
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
            do {
                let document = try decoder.decode(RuntimeHintsDocument.self, from: data)
                return try validated(
                    RuntimeHintsLoad(hints: document.hints, legacy: document.legacyHints)
                )
            } catch let error as RuntimeHintStoreError {
                throw error
            } catch {
                throw RuntimeHintStoreError.decodingFailed(
                    path: fileURL.path,
                    reason: String(describing: error)
                )
            }
        case 2:
            do {
                let document = try decoder.decode(RuntimeHintsDocumentV2.self, from: data)
                return try validated(
                    RuntimeHintsLoad(
                        hints: document.hints.map { $0.migrated() },
                        legacy: document.legacyHints
                    )
                )
            } catch let error as RuntimeHintStoreError {
                throw error
            } catch {
                throw RuntimeHintStoreError.decodingFailed(
                    path: fileURL.path,
                    reason: String(describing: error)
                )
            }
        case 1:
            // v1 の wall-clock 情報を、そのまま安全な錨へ変換しない。
            // 本体を実測で確認できたものだけを、あとから変換する。
            do {
                let document = try decoder.decode(RuntimeHintsDocumentV1.self, from: data)
                return try validated(RuntimeHintsLoad(hints: [], legacy: document.hints))
            } catch let error as RuntimeHintStoreError {
                throw error
            } catch {
                throw RuntimeHintStoreError.decodingFailed(
                    path: fileURL.path,
                    reason: String(describing: error)
                )
            }
        default:
            throw RuntimeHintStoreError.unsupportedSchemaVersion(
                found: version,
                supported: RuntimeHintsDocument.currentSchemaVersion
            )
        }
    }

    public func save(_ hints: [RuntimeHint], legacy: [LegacyRuntimeHint] = []) throws {
        _ = try validated(RuntimeHintsLoad(hints: hints, legacy: legacy))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(
                RuntimeHintsDocument(hints: hints, legacyHints: legacy)
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
        try save([], legacy: [])
    }

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// AppStateがDictionary化する前に重複を拒否し、後勝ちの上書きを発生させない。
    private func validated(_ load: RuntimeHintsLoad) throws -> RuntimeHintsLoad {
        var serviceIDs: Set<UUID> = []
        for serviceID in load.hints.map(\.serviceID) + load.legacy.map(\.serviceID) {
            guard serviceIDs.insert(serviceID).inserted else {
                throw RuntimeHintStoreError.duplicateServiceID(serviceID)
            }
        }
        return load
    }
}
