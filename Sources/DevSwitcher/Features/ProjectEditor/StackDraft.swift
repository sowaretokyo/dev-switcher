import DevSwitcherCore
import Foundation

extension ProjectFormModel {
    struct StackDraft: Identifiable, Equatable {
        let id: UUID
        var name: String
        var type: ManagedStackType
        var executable: String
        var argumentsJSON: String
        var projectName: String
        var filesJSON: String
        var profilesJSON: String
        var upArgumentsJSON: String
        var ports: [PortDraft]
        var enabledByDefault: Bool
        var failurePolicy: FailurePolicy

        init(type: ManagedStackType) {
            id = UUID(); self.type = type; name = type.displayName
            executable = "supabase"; argumentsJSON = "[\"start\"]"
            projectName = ""; filesJSON = ""; profilesJSON = ""; upArgumentsJSON = "[]"
            ports = []; enabledByDefault = true; failurePolicy = .block
        }
        init(_ stack: ManagedStackDefinition) {
            id = stack.id; name = stack.name; type = stack.type
            ports = stack.ports.map { PortDraft(id: $0.id, label: $0.label ?? "", port: String($0.port), isPrimary: $0.isPrimary, openURL: $0.openURL ?? "") }
            enabledByDefault = stack.enabledByDefault; failurePolicy = stack.failurePolicy
            switch stack.configuration {
            case let .supabase(config):
                executable = config.start.executable; argumentsJSON = Self.json(config.start.arguments)
                projectName = ""; filesJSON = ""; profilesJSON = ""; upArgumentsJSON = "[]"
            case let .dockerCompose(config):
                executable = "supabase"; argumentsJSON = "[\"start\"]"
                projectName = config.projectName ?? ""; filesJSON = config.files.map(Self.json) ?? ""
                profilesJSON = config.profiles.map(Self.json) ?? ""; upArgumentsJSON = Self.json(config.upArguments)
            }
        }
        @MainActor func build(directory: URL) throws -> ManagedStackDefinition {
            let (parsed, errors) = ProjectFormModel.tryParsePorts(ports, serviceLabel: name)
            guard errors.isEmpty else { throw ValidationFailure(errors: errors) }
            let configuration: ManagedStackConfiguration
            switch type {
            case .supabase:
                configuration = .supabase(SupabaseStackConfiguration(start: CommandSpec(executable: executable.trimmed, arguments: try Self.array(argumentsJSON), workingDirectory: directory)))
            case .dockerCompose:
                configuration = .dockerCompose(DockerComposeStackConfiguration(projectName: projectName.trimmed.isEmpty ? nil : projectName.trimmed,
                    files: filesJSON.trimmed.isEmpty ? nil : try Self.array(filesJSON), profiles: profilesJSON.trimmed.isEmpty ? nil : try Self.array(profilesJSON), upArguments: try Self.array(upArgumentsJSON)))
            }
            return ManagedStackDefinition(id: id, name: name.trimmed, configuration: configuration, ports: parsed, enabledByDefault: enabledByDefault, failurePolicy: failurePolicy)
        }
        static func array(_ text: String) throws -> [String] {
            do { return try JSONDecoder().decode([String].self, from: Data(text.utf8)) }
            catch { throw ComposeConfigurationError.invalid("引数・ファイル・profile は JSON の文字列配列で指定してください。\n\(error)") }
        }
        static func json(_ strings: [String]) -> String {
            // [String] の JSON エンコードは常に可能。失敗を空欄へ置き換えない。
            do { return String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
            catch { preconditionFailure("文字列配列を JSON にできません。\(error)") }
        }
    }
}

extension ProjectFormModel.ServiceDraft {
    func stopCommand(workingDirectory: URL) throws -> CommandSpec? {
        guard hasStopCommand else { return nil }
        return CommandSpec(executable: stopExecutable.trimmed,
            arguments: try ProjectFormModel.StackDraft.array(stopArgumentsJSON),
            workingDirectory: stopDirectory ?? workingDirectory)
    }
}

extension ProjectFormModel.ServiceDraft {
    var commandWarnings: [String] {
        do {
            let command = CommandSpec(executable: executable, arguments: try parsedArguments, workingDirectory: URL(fileURLWithPath: "/"))
            var messages: [String] = []
            let basename = URL(fileURLWithPath: executable).lastPathComponent
            if ["docker", "docker-compose"].contains(basename) {
                messages.append(ValidationWarning.containerCommandAsProcess(service: name, executable: basename).description)
            }
            if ProcessCommandClassification.supabaseStart(command) == .possible {
                messages.append(ValidationWarning.possibleSupabaseStart(service: name).description)
            }
            return messages
        } catch { return ["引数を解析できません。\(error)"] }
    }
}
