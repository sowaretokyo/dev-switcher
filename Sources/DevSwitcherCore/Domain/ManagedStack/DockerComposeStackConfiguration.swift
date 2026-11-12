import Foundation

/// 許可する追加引数と禁止操作を、設定検証・コマンド生成・実行境界で共有する。
public enum ComposeCommandRules {
    public static let forbiddenSubcommands: Set<String> = ["down", "rm", "kill"]
    public static let forbiddenArguments: Set<String> = ["-v", "--volumes", "--rmi", "--remove-orphans", "-V", "--renew-anon-volumes"]
    /// スタックの同一性はプロジェクト名。停止では設定外の profile も含める。
    public static let stopProfiles = ["*"]
    public static let removedEnvironmentKeys: Set<String> = ["COMPOSE_PROJECT_NAME", "COMPOSE_FILE", "COMPOSE_PROFILES"]
    private static let flags: Set<String> = ["--build", "--no-build", "--wait", "--force-recreate", "--no-recreate", "--no-deps", "--quiet-pull"]

    public static func validateUpArguments(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            defer { index += 1 }
            if flags.contains(argument) { continue }
            if argument == "--pull" || argument == "--wait-timeout" {
                guard index + 1 < arguments.count else { throw invalid(argument) }
                index += 1
                try validateValue(arguments[index], option: argument)
            } else if argument.hasPrefix("--pull=") {
                try validateValue(String(argument.dropFirst(7)), option: "--pull")
            } else if argument.hasPrefix("--wait-timeout=") {
                try validateValue(String(argument.dropFirst(15)), option: "--wait-timeout")
            } else {
                guard let first = argument.utf8.first, asciiAlphanumeric(first),
                      argument.utf8.allSatisfy({ asciiAlphanumeric($0) || [45, 46, 95].contains($0) }) else { throw invalid(argument) }
            }
        }
    }
    public static func validateCommand(_ command: CommandSpec) throws {
        guard URL(fileURLWithPath: command.executable).lastPathComponent == "docker" else { throw invalid(command.executable) }
        let args = command.arguments
        guard args.count >= 6, args[0] == "compose", args[1] == "-p", ComposeProjectName(rawValue: args[2]) != nil else { throw invalid(command.displayCommandLine) }
        var index = 3, fileCount = 0
        var profiles: [String] = []
        while index < args.count, args[index] == "-f" || args[index] == "--profile" {
            guard index + 1 < args.count else { throw invalid(args[index]) }
            if args[index] == "-f" {
                guard args[index + 1].hasPrefix("/") else { throw invalid(args[index + 1]) }
                fileCount += 1
            } else {
                guard !args[index + 1].isEmpty else { throw invalid(args[index + 1]) }
                profiles.append(args[index + 1])
            }
            index += 2
        }
        guard fileCount > 0, index < args.count else { throw invalid(command.displayCommandLine) }
        let suffix = Array(args[index...])
        guard !forbiddenSubcommands.contains(suffix[0]) else { throw invalid(suffix[0]) }
        if suffix == ["stop"] {
            guard profiles == stopProfiles else {
                throw ComposeConfigurationError.invalid(L10n.text("Compose の停止には --profile '*' を指定してください。同じプロジェクト名の全 profile が停止対象です。"))
            }
            return
        }
        if suffix == ["ps", "--all", "--format", "json"] { return }
        guard suffix.count >= 2, suffix[0] == "up", suffix[1] == "-d" else { throw invalid(command.displayCommandLine) }
        try validateUpArguments(Array(suffix.dropFirst(2)))
    }
    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    private static func validateValue(_ value: String, option: String) throws {
        if option == "--pull" {
            guard ["always", "missing", "never"].contains(value) else { throw invalid(option + "=" + value) }
        } else {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value), number > 0 else { throw invalid(option + "=" + value) }
        }
    }
    private static func invalid(_ value: String) -> ComposeConfigurationError {
        .invalid(L10n.text("Compose の upArguments に「\(value)」は指定できません。許可されたオプションとサービス名だけを指定してください。"))
    }
}

public struct DockerComposeStackConfiguration: Equatable, Sendable, Codable {
    public var projectName: String?
    public var files: [String]?
    public var profiles: [String]?
    public var upArguments: [String]

    public init(projectName: String? = nil, files: [String]? = nil, profiles: [String]? = nil, upArguments: [String] = []) {
        self.projectName = projectName; self.files = files; self.profiles = profiles; self.upArguments = upArguments
    }
    public func validate() throws {
        if let projectName, ComposeProjectName(rawValue: projectName) == nil {
            throw ComposeConfigurationError.invalid(L10n.text("Compose の projectName「\(projectName)」は不正です。"))
        }
        if let files {
            guard !files.isEmpty, files.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("/") && !$0.hasPrefix("~") && !$0.contains("\0") }) else {
                throw ComposeConfigurationError.invalid(L10n.text("Compose の files は1件以上の相対パスで指定してください。"))
            }
        }
        if let profiles {
            guard !profiles.isEmpty, profiles.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0") }) else {
                throw ComposeConfigurationError.invalid(L10n.text("Compose の profiles は1件以上の空でない文字列で指定してください。"))
            }
        }
        try ComposeCommandRules.validateUpArguments(upArguments)
    }
    public func resolve(workingDirectory: URL) throws -> DockerComposeResolvedConfiguration {
        try validate()
        let urls = try ComposeFileLocator.locate(files: files, workingDirectory: workingDirectory)
        let name = try ComposeProjectNameReader.resolve(explicit: projectName, files: urls)
        return DockerComposeResolvedConfiguration(workingDirectory: workingDirectory, projectName: name, files: urls, profiles: profiles ?? [], upArguments: upArguments)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case projectName, files, profiles, upArguments }
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try c.optional(String.self, forKey: .projectName)
        files = try c.optional([String].self, forKey: .files)
        profiles = try c.optional([String].self, forKey: .profiles)
        upArguments = try c.decode([String].self, forKey: .upArguments)
    }
}

public struct DockerComposeFingerprint: Codable, Equatable, Sendable {
    public let workingDirectory: URL
    public let projectName: String
    public let files: [URL]
    public let profiles: [String]
    public let upArguments: [String]
}

public struct DockerComposeResolvedConfiguration: Equatable, Sendable {
    public let fingerprint: DockerComposeFingerprint
    public var identity: ManagedStackIdentity { ManagedStackIdentity(validatedType: .dockerCompose, value: fingerprint.projectName) }
    init(workingDirectory: URL, projectName: ComposeProjectName, files: [URL], profiles: [String], upArguments: [String]) {
        fingerprint = DockerComposeFingerprint(workingDirectory: workingDirectory.standardizedFileURL, projectName: projectName.rawValue, files: files, profiles: profiles, upArguments: upArguments)
    }
    public var startCommand: CommandSpec { command(["up", "-d"] + fingerprint.upArguments) }
    public var observationCommand: CommandSpec { command(["ps", "--all", "--format", "json"]) }
    public var stopCommand: CommandSpec { command(["stop"], profiles: ComposeCommandRules.stopProfiles) }
    private func command(_ arguments: [String], profiles: [String]? = nil) -> CommandSpec {
        var prefix = ["compose", "-p", fingerprint.projectName]
        for file in fingerprint.files { prefix += ["-f", file.path] }
        for profile in profiles ?? fingerprint.profiles { prefix += ["--profile", profile] }
        return CommandSpec(executable: "docker", arguments: prefix + arguments, workingDirectory: fingerprint.workingDirectory)
    }
}
