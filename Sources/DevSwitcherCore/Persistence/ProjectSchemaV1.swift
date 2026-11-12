import Foundation

/// schema version 1 のスナップショット。
///
/// 現行の `ProjectDefinition` で読むと、v1 に存在しなかった `stopOrder` / `enabledNow` / `stop` が
/// 「キーが無いので既定値」として黙って埋まる。それは暗黙のフォールバックなので、
/// v1 は当時の形のまま読み、現行形式への変換をこのファイルに明示的に書く。
///
/// v1 の形を後から変えてはいけない。過去に書き出したファイルの定義そのものだから。
enum ProjectSchemaV1 {
    struct Document: Decodable {
        let schemaVersion: Int
        let projects: [Project]
    }

    struct Project: Decodable {
        let id: UUID
        let name: String
        let color: ProjectColor
        let directory: URL
        let services: [Service]
    }

    struct Service: Decodable {
        let id: UUID
        let name: String
        let kind: ProjectSchemaV3.ServiceKind
        let ports: [PortSpec]
        let start: CommandSpec
        let enabledByDefault: Bool
        let failurePolicy: FailurePolicy
    }

    /// v1 → 現行形式。
    ///
    /// - `stopOrder`: v1 に終了順の概念が無かったため、既定（起動順の逆）を使う nil にする。
    /// - `enabledNow`: v1 には今回の起動対象が無かったため、`enabledByDefault` に従う空の指定にする。
    /// - `stop`: v1 に終了コマンドが無かったため、プロセスグループ停止を意味する nil にする。
    ///
    /// いずれも「値が無いから既定」ではなく「v1 の意味を現行形式で表すとこうなる」という変換として書く。
    static func migrate(_ document: Document) throws -> [ProjectDefinition] {
        try document.projects.map { project in
            let services = project.services.map {
                ProjectSchemaV3.Service(id: $0.id, name: $0.name, kind: $0.kind, ports: $0.ports,
                    start: $0.start, stop: nil, enabledByDefault: $0.enabledByDefault, failurePolicy: $0.failurePolicy)
            }
            let grouping = ProjectDefinition(id: project.id, name: project.name, color: project.color,
                directory: project.directory, services: services.map {
                    ServiceDefinition(id: $0.id, name: $0.name, ports: $0.ports, start: $0.start,
                        enabledByDefault: $0.enabledByDefault, failurePolicy: $0.failurePolicy)
                })
            return try ProjectSchemaV3.convert(id: project.id, name: project.name, color: project.color,
                directories: grouping.workingDirectories, services: services, stopOrder: nil, enabledNow: nil)
        }
    }
}
