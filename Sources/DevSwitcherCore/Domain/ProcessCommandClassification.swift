import Foundation

public enum ValidationWarning: Equatable, Sendable, CustomStringConvertible {
    case containerCommandAsProcess(service: String, executable: String)
    case possibleSupabaseStart(service: String)
    public var description: String {
        switch self {
        case let .containerCommandAsProcess(service, executable):
            "プロセス「\(service)」は \(executable) を実行します。停止はプロセスグループ単位であり、コンテナは残り得ます。コンテナまで管理する場合は Docker Compose スタックとして登録してください。"
        case let .possibleSupabaseStart(service):
            "プロセス「\(service)」は Supabase の起動コマンドの可能性があります。Supabase の起動なら管理対象スタックとして登録してください。"
        }
    }
}

public enum ProcessCommandClassification {
    public enum SupabaseStart { case none, possible, certain }
    public static func supabaseStart(_ command: CommandSpec) -> SupabaseStart {
        let executable = URL(fileURLWithPath: command.executable).lastPathComponent
        if executable == "supabase" {
            let config = SupabaseStackConfiguration(start: command)
            if config.startSubcommandIndex != nil { return .certain }
        }
        for (index, token) in command.arguments.enumerated() where token == "supabase" || token.hasPrefix("supabase@") {
            guard index + 1 < command.arguments.count, command.arguments[index + 1] == "start" else { continue }
            return index > 0 && command.arguments[index - 1].hasPrefix("-") ? .possible : .certain
        }
        return .none
    }
}

extension ProjectValidator {
    public static func warnings(_ project: ProjectDefinition) -> [ValidationWarning] {
        project.services.flatMap { service -> [ValidationWarning] in
            var result: [ValidationWarning] = []
            let name = URL(fileURLWithPath: service.start.executable).lastPathComponent
            if ["docker", "docker-compose"].contains(name) {
                result.append(.containerCommandAsProcess(service: service.name, executable: name))
            }
            if ProcessCommandClassification.supabaseStart(service.start) == .possible {
                result.append(.possibleSupabaseStart(service: service.name))
            }
            return result
        }
    }
}
