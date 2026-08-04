import Foundation

/// 古いPIDやポートを復元しないよう、保存形式にはプロジェクト定義だけを含める。
public struct ProjectsDocument: Codable, Sendable {
    /// version 2 で終了順（`stopOrder`）、今回の起動対象（`enabledNow`）、終了コマンド（`stop`）を追加した。
    public static let currentSchemaVersion = 2
    /// 明示的な変換を書いてある過去バージョン。ここに無いバージョンは読まない。
    public static let migratableSchemaVersions = [1]

    public var schemaVersion: Int
    public var projects: [ProjectDefinition]

    public init(schemaVersion: Int = ProjectsDocument.currentSchemaVersion, projects: [ProjectDefinition]) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }
}

public enum ProjectStoreError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case decodingFailed(path: String, reason: String)
    case invalidStoredProject(name: String, errors: [ValidationError])
    case writeFailed(path: String, reason: String)
    case applicationSupportUnavailable(reason: String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            "設定ファイルのスキーマバージョン \(found) は未対応です（対応バージョン: \(supported)）。"
        case let .decodingFailed(path, reason):
            "設定ファイルを読み込めませんでした（\(path)）。\n\(reason)"
        case let .invalidStoredProject(name, errors):
            "保存済みのプロジェクト「\(name)」の設定が不正です。\n"
                + errors.map(\.description).joined(separator: "\n")
        case let .writeFailed(path, reason):
            "設定ファイルを保存できませんでした（\(path)）。\n\(reason)"
        case let .applicationSupportUnavailable(reason):
            "Application Support ディレクトリを利用できません。\n\(reason)"
        }
    }
}

/// 保存中の中断で既存設定を壊さないよう、atomicに書き換える。
public struct ProjectStore: Sendable {
    public static let fileName = "projects.json"
    public static let directoryName = "DevSwitcher"

    public let directory: URL

    public var fileURL: URL {
        directory.appendingPathComponent(ProjectStore.fileName, isDirectory: false)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultStore() throws -> ProjectStore {
        ProjectStore(directory: try ApplicationPaths.applicationSupportDirectory())
    }

    /// IDで除くと重複相手まで消えるため、保存対象自身は位置で除外する。
    private static func projects(
        _ projects: [ProjectDefinition],
        excluding index: Int
    ) -> [ProjectDefinition] {
        projects.enumerated()
            .filter { $0.offset != index }
            .map(\.element)
    }

    public func load() throws -> [ProjectDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProjectStoreError.decodingFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let projects = try ProjectStore.decode(data, path: fileURL.path)

        // 移動したリポジトリの設定も読めるよう、ここではファイルシステムを検証しない。
        // IDで除くと重複相手まで消えるため、自身だけを位置で除外する。
        for (index, project) in projects.enumerated() {
            let others = ProjectStore.projects(projects, excluding: index)
            let errors = ProjectValidator.structuralErrors(project, existingProjects: others)
            guard errors.isEmpty else {
                throw ProjectStoreError.invalidStoredProject(name: project.name, errors: errors)
            }
        }

        return projects
    }

    /// 先にスキーマバージョンだけを読み、バージョンごとに対応する型でデコードする。
    /// 現行型で一律にデコードすると、旧バージョンに無かったキーが既定値で埋まり、
    /// 変換したのか元からその値だったのかが区別できなくなる。
    static func decode(_ data: Data, path: String) throws -> [ProjectDefinition] {
        let decoder = JSONDecoder()

        let version: Int
        do {
            version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
        } catch {
            throw ProjectStoreError.decodingFailed(path: path, reason: String(describing: error))
        }

        switch version {
        case ProjectsDocument.currentSchemaVersion:
            do {
                return try decoder.decode(ProjectsDocument.self, from: data).projects
            } catch {
                throw ProjectStoreError.decodingFailed(path: path, reason: String(describing: error))
            }
        case 1:
            do {
                let legacy = try decoder.decode(ProjectSchemaV1.Document.self, from: data)
                return ProjectSchemaV1.migrate(legacy)
            } catch {
                throw ProjectStoreError.decodingFailed(path: path, reason: String(describing: error))
            }
        default:
            throw ProjectStoreError.unsupportedSchemaVersion(
                found: version,
                supported: ProjectsDocument.currentSchemaVersion
            )
        }
    }

    /// バージョン判定だけを行う最小の型。判定前に本体を解釈しない。
    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    public func save(_ projects: [ProjectDefinition]) throws {
        for (index, project) in projects.enumerated() {
            let others = ProjectStore.projects(projects, excluding: index)
            try ProjectValidator.check(project, existingProjects: others)
        }

        let document = ProjectsDocument(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw ProjectStoreError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }
}
