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
        let kind: ServiceKind
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
    static func migrate(_ document: Document) -> [ProjectDefinition] {
        document.projects.map { project in
            ProjectDefinition(
                id: project.id,
                name: project.name,
                color: project.color,
                directory: project.directory,
                services: project.services.map { service in
                    ServiceDefinition(
                        id: service.id,
                        name: service.name,
                        kind: service.kind,
                        ports: service.ports,
                        start: service.start,
                        stop: nil,
                        enabledByDefault: service.enabledByDefault,
                        failurePolicy: service.failurePolicy
                    )
                },
                stopOrder: nil,
                enabledNow: [:]
            )
        }
    }
}
