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
        let services: [ProjectSchemaV3.Service]
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
            let grouping = ProjectDefinition(id: project.id, name: project.name, color: project.color,
                directory: project.directory, services: project.services.map {
                    ServiceDefinition(id: $0.id, name: $0.name, ports: $0.ports, start: $0.start,
                        enabledByDefault: $0.enabledByDefault, failurePolicy: $0.failurePolicy)
                })
            return try ProjectSchemaV3.convert(id: project.id, name: project.name, color: project.color,
                directories: grouping.workingDirectories, services: project.services, stopOrder: project.stopOrder,
                enabledNow: project.enabledNow)
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
