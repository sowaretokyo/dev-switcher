import Foundation

/// schema version 2 のスナップショット。
///
/// v2 は開発環境直下に代表ディレクトリを1つ持ち、各サービスが実際の作業ディレクトリを
/// `CommandSpec` に重複して保持していた。v3 では作業パスごとに名前付きグループへ変換する。
enum ProjectSchemaV2 {
    struct Document: Decodable {
        let schemaVersion: Int
        let projects: [Project]
    }

    struct Project: Decodable {
        let id: UUID
        let name: String
        let color: ProjectColor
        let directory: URL
        let services: [ServiceDefinition]
        let stopOrder: [UUID]?
        let enabledNow: [String: Bool]?
    }

    static func migrate(_ document: Document) throws -> [ProjectDefinition] {
        try document.projects.map { project in
            var parsedEnabledNow: [UUID: Bool] = [:]
            for (key, value) in project.enabledNow ?? [:] {
                guard let serviceID = UUID(uuidString: key) else {
                    throw MigrationError.invalidEnabledNowKey(key)
                }
                parsedEnabledNow[serviceID] = value
            }
            return ProjectDefinition(
                id: project.id,
                name: project.name,
                color: project.color,
                directory: project.directory,
                services: project.services,
                stopOrder: project.stopOrder,
                enabledNow: parsedEnabledNow
            )
        }
    }

    enum MigrationError: Error, CustomStringConvertible {
        case invalidEnabledNowKey(String)

        var description: String {
            switch self {
            case let .invalidEnabledNowKey(key):
                "起動対象のキー「\(key)」をサービス ID として解釈できません。"
            }
        }
    }
}
