import Foundation

/// v3 の読み込み専用スナップショット。通常プロセスと Supabase を明示的に分離する。
enum ProjectSchemaV3 {
    enum ServiceKind: String, Codable, Sendable, CaseIterable {
        case web
        case expo
        case supabase
        case inngest
        case docker
        case worker
        case other

        var displayName: String {
            switch self {
            case .web: "Web"
            case .expo: "Expo"
            case .supabase: "Supabase"
            case .inngest: "Inngest"
            case .docker: "Docker"
            case .worker: "Worker / Watcher"
            case .other: L10n.text("その他")
            }
        }
    }


    struct Service: Codable, Sendable {
        var id: UUID
        var name: String
        var kind: ServiceKind
        var ports: [PortSpec]
        var start: CommandSpec
        var stop: CommandSpec?
        var enabledByDefault: Bool
        var failurePolicy: FailurePolicy
    }
    struct Directory: Decodable {
        let id: UUID
        let name: String
        let directory: URL
        let serviceIDs: [UUID]
    }
    struct Project: Decodable {
        let id: UUID
        let name: String
        let color: ProjectColor
        let workingDirectories: [Directory]
        let services: [Service]
        let stopOrder: [UUID]?
        let enabledNow: [String: Bool]?
    }
    struct Document: Decodable {
        let schemaVersion: Int
        let projects: [Project]
    }

    static func migrate(_ document: Document) throws -> [ProjectDefinition] {
        try document.projects.map { project in
            try convert(id: project.id, name: project.name, color: project.color,
                directories: project.workingDirectories.map {
                    WorkingDirectoryDefinition(id: $0.id, name: $0.name, directory: $0.directory, serviceIDs: $0.serviceIDs)
                }, services: project.services, stopOrder: project.stopOrder, enabledNow: project.enabledNow)
        }
    }

    static func convert(id: UUID, name: String, color: ProjectColor,
        directories: [WorkingDirectoryDefinition], services: [Service],
        stopOrder: [UUID]?, enabledNow: [String: Bool]?) throws -> ProjectDefinition {
        let stacks = services.filter { $0.kind == .supabase }
        guard stacks.count <= 1 else {
            throw ComposeConfigurationError.invalid(L10n.text("開発環境「\(name)」に Supabase が複数あります。変換できません。"))
        }
        if let invalid = stacks.first(where: { $0.stop != nil }) {
            throw ComposeConfigurationError.invalid(L10n.text("開発環境「\(name)」の Supabase「\(invalid.name)」に stop があるため変換できません。"))
        }
        let stackIDs = Set(stacks.map(\.id))
        var enabled: [UUID: Bool] = [:]
        for (key, value) in enabledNow ?? [:] {
            guard let uuid = UUID(uuidString: key), enabled[uuid] == nil else {
                throw ComposeConfigurationError.invalid(L10n.text("起動対象の ID が不正または重複しています（\(key)）。"))
            }
            enabled[uuid] = value
        }
        var result = ProjectDefinition(id: id, name: name, color: color,
            workingDirectories: directories.map { directory in
                var value = directory
                value.stackIDs = directory.serviceIDs.filter { stackIDs.contains($0) }
                value.serviceIDs = directory.serviceIDs.filter { !stackIDs.contains($0) }
                return value
            }, services: services.filter { $0.kind != .supabase }.map {
                ServiceDefinition(id: $0.id, name: $0.name, tag: $0.kind.rawValue, ports: $0.ports,
                    start: $0.start, stop: $0.stop, enabledByDefault: $0.enabledByDefault, failurePolicy: $0.failurePolicy)
            }, managedStacks: stacks.map {
                ManagedStackDefinition(id: $0.id, name: $0.name,
                    configuration: .supabase(SupabaseStackConfiguration(start: $0.start)),
                    ports: $0.ports, enabledByDefault: $0.enabledByDefault, failurePolicy: $0.failurePolicy)
            }, stopOrder: stopOrder.map { $0.filter { !stackIDs.contains($0) } }, enabledNow: enabled)
        let oldStart = services.map(\.id)
        let oldStop = stopOrder ?? Array(oldStart.reversed())
        let newStart = stacks.map(\.id) + result.services.map(\.id)
        let newStop = (result.stopOrder ?? Array(result.services.map(\.id).reversed())) + stacks.reversed().map(\.id)
        if oldStart != newStart || oldStop != newStop {
            result.migrationNotice = L10n.text("開発環境「\(name)」の起動・停止順を変換しました。スタックを先に起動し、プロセスの後に停止します。プロセス同士の順序は維持しています。")
        }
        return result
    }
}
