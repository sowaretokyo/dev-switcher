import Foundation
@testable import DevSwitcherCore

// v3 世代のテスト入力を、v4 のプロセス／スタックへ明示的に射影する。
// 保存・実行する本体には旧 kind を持ち込まない。
typealias ServiceKind = ProjectSchemaV3.ServiceKind

extension LaunchUnit {
    init(_ unit: LaunchUnit) { self = unit }
    static func process(_ unit: LaunchUnit) -> LaunchUnit {
        precondition(unit.processDefinition != nil, "通常プロセスではありません。")
        return unit
    }

    init(id: UUID = UUID(), name: String, kind: ServiceKind, ports: [PortSpec], start: CommandSpec, stop: CommandSpec? = nil, enabledByDefault: Bool, failurePolicy: FailurePolicy) {
        if kind == .supabase {
            self = .stack(ManagedStackDefinition(id: id, name: name, configuration: .supabase(SupabaseStackConfiguration(start: start, stop: stop)), ports: ports, enabledByDefault: enabledByDefault, failurePolicy: failurePolicy), workingDirectory: start.workingDirectory)
        } else {
            self = .process(DevSwitcherCore.ServiceDefinition(id: id, name: name, tag: kind.rawValue, ports: ports, start: start, stop: stop, enabledByDefault: enabledByDefault, failurePolicy: failurePolicy))
        }
    }
    var start: CommandSpec {
        get {
            switch self {
            case let .process(value): return value.start
            case let .stack(value, _):
                guard case let .supabase(config) = value.configuration else { preconditionFailure("Supabase fixture ではありません。") }
                return config.start
            }
        }
        set {
            switch self {
            case var .process(value): value.start = newValue; self = .process(value)
            case let .stack(original, _):
                var value = original
                guard case var .supabase(config) = value.configuration else { preconditionFailure("Supabase fixture ではありません。") }
                config.start = newValue; value.configuration = .supabase(config)
                self = .stack(value, workingDirectory: newValue.workingDirectory)
            }
        }
    }
    var stop: CommandSpec? {
        get {
            switch self {
            case let .process(value): value.stop
            case let .stack(value, _):
                switch value.configuration { case let .supabase(config): config.stop; case .dockerCompose: nil }
            }
        }
        set {
            switch self {
            case var .process(value): value.stop = newValue; self = .process(value)
            case let .stack(original, directory):
                var value = original
                guard case var .supabase(config) = value.configuration else { preconditionFailure("Supabase fixture ではありません。") }
                config.stop = newValue; value.configuration = .supabase(config); self = .stack(value, workingDirectory: directory)
            }
        }
    }
    var kind: ServiceKind {
        get {
            if managedStackDefinition != nil { return .supabase }
            guard let tag = processDefinition?.tag, let kind = ServiceKind(rawValue: tag) else { preconditionFailure("旧種別を持たない fixture です。") }
            return kind
        }
        set {
            self = LaunchUnit(id: id, name: name, kind: newValue, ports: ports, start: start, stop: stop, enabledByDefault: enabledByDefault, failurePolicy: failurePolicy)
        }
    }
    var usesProcessGroupStop: Bool { managedStackDefinition == nil && stop == nil }
}

extension ProjectDefinition {
    init(id: UUID = UUID(), name: String, color: ProjectColor, workingDirectories: [WorkingDirectoryDefinition], services: [LaunchUnit], stopOrder: [UUID]? = nil, enabledNow: [UUID: Bool] = [:]) {
        let stacks = services.compactMap(\.managedStackDefinition)
        let ids = Set(stacks.map(\.id))
        self.init(id: id, name: name, color: color,
            workingDirectories: workingDirectories.map { directory in
                var value = directory
                value.stackIDs += value.serviceIDs.filter { ids.contains($0) }
                value.serviceIDs.removeAll { ids.contains($0) }
                return value
            }, services: services.compactMap(\.processDefinition), managedStacks: stacks,
            stopOrder: stopOrder.map { $0.filter { !ids.contains($0) } }, enabledNow: enabledNow)
    }
    init(id: UUID = UUID(), name: String, color: ProjectColor, directory: URL, services: [LaunchUnit], stopOrder: [UUID]? = nil, enabledNow: [UUID: Bool] = [:]) {
        var directories: [WorkingDirectoryDefinition] = []
        for unit in services {
            if let index = directories.firstIndex(where: { $0.directory == unit.workingDirectory }) {
                directories[index].serviceIDs.append(unit.id)
            } else {
                let count = directories.filter { $0.directory.lastPathComponent == unit.workingDirectory.lastPathComponent }.count
                directories.append(WorkingDirectoryDefinition(name: unit.workingDirectory.lastPathComponent + (count == 0 ? "" : " (\(count + 1))"), directory: unit.workingDirectory, serviceIDs: [unit.id]))
            }
        }
        if directories.isEmpty { directories = [WorkingDirectoryDefinition(name: directory.lastPathComponent, directory: directory, serviceIDs: [])] }
        self.init(id: id, name: name, color: color, workingDirectories: directories, services: services, stopOrder: stopOrder, enabledNow: enabledNow)
    }
}
