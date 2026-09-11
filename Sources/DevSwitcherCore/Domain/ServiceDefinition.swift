import Foundation

public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case web
    case expo
    case supabase
    case inngest
    case docker
    case worker
    case other

    public var displayName: String {
        switch self {
        case .web: "Web"
        case .expo: "Expo"
        case .supabase: "Supabase"
        case .inngest: "Inngest"
        case .docker: "Docker"
        case .worker: "Worker / Watcher"
        case .other: "その他"
        }
    }
}

/// 起動対象かどうかと、失敗時に全体を止めるかは独立した判断なので型を分ける。
public enum FailurePolicy: String, Codable, Sendable, CaseIterable {
    case block
    case `continue`

    public var displayName: String {
        switch self {
        case .block: "開発環境全体を失敗にする"
        case .continue: "一部停止として続行する"
        }
    }
}

public struct ServiceDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ServiceKind
    /// workerやwatcherはポートを持たないため、空配列を有効とする。
    public var ports: [PortSpec]
    public var start: CommandSpec
    /// 起動コマンド自身が終了してもサービスが残るもののカスタム終了方法。
    /// MVPでは未対応。通常プロセスはnilならプロセスグループで停止し、Supabaseは
    /// nilの場合だけ起動コマンドと同じCLIから`stop`を導出する。
    public var stop: CommandSpec?
    public var enabledByDefault: Bool
    public var failurePolicy: FailurePolicy

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ServiceKind,
        ports: [PortSpec],
        start: CommandSpec,
        stop: CommandSpec? = nil,
        enabledByDefault: Bool,
        failurePolicy: FailurePolicy
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ports = ports
        self.start = start
        self.stop = stop
        self.enabledByDefault = enabledByDefault
        self.failurePolicy = failurePolicy
    }

    public var primaryPort: PortSpec? {
        ports.first(where: \.isPrimary)
    }


    /// Supabase CLIの起動コマンドから、設定ディレクトリと派生コマンドを構造化して導出する。
    /// 導出できない形式は既定へ倒さず nil を返し、呼び出し側が起動前に失敗させる。
    public var supabaseConfiguration: SupabaseServiceConfiguration? {
        guard kind == .supabase,
              stop == nil,
              let startIndex = supabaseStartSubcommandIndex,
              !Self.forbiddenStopOptions.contains(where: start.arguments.contains),
              let workdir = supabaseWorkdirArgument() else {
            return nil
        }
        let configDirectory = workdir.map { value -> URL in
            value.hasPrefix("/")
                ? URL(fileURLWithPath: value).standardizedFileURL
                : start.workingDirectory.appendingPathComponent(value).standardizedFileURL
        } ?? start.workingDirectory.standardizedFileURL

        return SupabaseServiceConfiguration(
            serviceID: id,
            serviceName: name,
            start: start,
            globalOptions: Self.derivedGlobalOptions(Array(start.arguments[..<startIndex])),
            configDirectory: configDirectory
        )
    }

    /// `--workdir`はグローバルオプションで、サブコマンドの前後どちらにも置ける。
    /// 戻り値の`nil`は「指定なし」、`.some(nil)`は作らず、値の欠落は導出失敗にする。
    private func supabaseWorkdirArgument() -> String?? {
        var result: String?
        var index = 0
        while index < start.arguments.count {
            let argument = start.arguments[index]
            if argument == "--workdir" {
                let valueIndex = index + 1
                guard valueIndex < start.arguments.count else { return nil }
                let value = start.arguments[valueIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
                result = value
                index += 2
                continue
            }
            if argument.hasPrefix("--workdir=") {
                let value = String(argument.dropFirst("--workdir=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
                result = value
            }
            index += 1
        }
        return .some(result)
    }

    /// 派生コマンドへ引き継ぐグローバル引数。
    /// `--workdir`と`--output`はこちらで必ず明示するため、二重指定にならないよう落とす。
    private static func derivedGlobalOptions(_ prefix: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < prefix.count {
            let argument = prefix[index]
            if argument == "--workdir" || argument == "--output" || argument == "-o" {
                index += 2
                continue
            }
            if argument.hasPrefix("--workdir=") || argument.hasPrefix("--output=") {
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    /// ラッパーの任意の`start`をSupabaseサブコマンドと誤認しないため、
    /// 実行ファイルとパッケージ位置を特定できる形式だけを受け付ける。
    var hasSupportedSupabaseInvocation: Bool {
        supabaseSubcommandStartIndex != nil
    }

    var hasSupabaseStartSubcommand: Bool {
        supabaseStartSubcommandIndex != nil
    }

    var usesForbiddenSupabaseStopOption: Bool {
        Self.forbiddenStopOptions.contains(where: start.arguments.contains)
    }

    public var supabaseConfigurationFailureReason: String {
        if stop != nil {
            return "Supabaseの終了コマンドは起動コマンドから導出するため、個別には指定できません。"
        }
        if !hasSupportedSupabaseInvocation {
            return "起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
        }
        if !hasSupabaseStartSubcommand {
            return "起動コマンドに `start` サブコマンドがありません。"
        }
        if usesForbiddenSupabaseStopOption {
            return "起動コマンドに `--all` と `--no-backup` は指定できません。"
        }
        return "`--workdir` にディレクトリが指定されていません。"
    }

    private var supabaseStartSubcommandIndex: Int? {
        guard var index = supabaseSubcommandStartIndex else { return nil }

        while index < start.arguments.count {
            let argument = start.arguments[index]
            if argument == "start" { return index }

            if Self.supabaseBooleanGlobalOptions.contains(argument) {
                index += 1
                continue
            }
            if Self.supabaseValueGlobalOptions.contains(argument) {
                let valueIndex = index + 1
                guard valueIndex < start.arguments.count,
                      !start.arguments[valueIndex].isEmpty,
                      !start.arguments[valueIndex].hasPrefix("-") else {
                    return nil
                }
                index += 2
                continue
            }
            if let separator = argument.firstIndex(of: "="),
               Self.supabaseValueGlobalOptions.contains(String(argument[..<separator])),
               !argument[argument.index(after: separator)...].isEmpty {
                index += 1
                continue
            }
            return nil
        }
        return nil
    }

    /// Supabaseのサブコマンドが始まる最初の位置。
    /// 対応形式は直接実行と`pnpm exec` / `npx` / `pnpx`に限定する。
    private var supabaseSubcommandStartIndex: Int? {
        let executable = URL(fileURLWithPath: start.executable).lastPathComponent
        switch executable {
        case "supabase":
            return 0
        case "pnpm":
            guard start.arguments.count >= 2,
                  start.arguments[0] == "exec",
                  Self.isSupabasePackage(start.arguments[1]) else {
                return nil
            }
            return 2
        case "npx", "pnpx":
            guard let package = start.arguments.first,
                  Self.isSupabasePackage(package) else {
                return nil
            }
            return 1
        default:
            return nil
        }
    }

    private static func isSupabasePackage(_ argument: String) -> Bool {
        argument == "supabase"
            || (argument.hasPrefix("supabase@") && argument.count > "supabase@".count)
    }

    private static let supabaseBooleanGlobalOptions: Set<String> = [
        "--create-ticket", "--debug", "--experimental", "--yes",
    ]

    private static let supabaseValueGlobalOptions: Set<String> = [
        "--dns-resolver", "--network-id", "--output", "--profile", "--workdir", "-o",
    ]

    /// 複数プロジェクトやバックアップを巻き込むため、どの経路でも受け付けない。
    static let forbiddenStopOptions: Set<String> = ["--all", "--no-backup"]

    /// 停止方法がプロセスグループのシグナルで完結するか。
    public var usesProcessGroupStop: Bool {
        kind != .supabase && stop == nil
    }
}

/// Supabaseスタックのlifecycleコマンドを組み立てる。
///
/// 生成できるのは`status`と、`--project-id`で対象を限定した`stop`だけ。
/// `--all`、`--no-backup`、任意の停止コマンドを表現できる入口を持たない。
public struct SupabaseServiceConfiguration: Equatable, Sendable {
    public let serviceID: UUID
    public let serviceName: String
    public let start: CommandSpec
    /// `start`より前に置かれたグローバル引数。`--workdir`と`--output`は含まない。
    private let globalOptions: [String]
    /// `project_id`を読む基準ディレクトリ。`--workdir`があればその値。
    public let configDirectory: URL

    init(
        serviceID: UUID,
        serviceName: String,
        start: CommandSpec,
        globalOptions: [String],
        configDirectory: URL
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.start = start
        self.globalOptions = globalOptions
        self.configDirectory = configDirectory
    }

    public var configFileURL: URL {
        SupabaseConfigFile.configFileURL(inConfigDirectory: configDirectory)
    }

    /// 設定ファイルから`project_id`を読む。値は推測・正規化しない。
    public func resolveProjectID() throws -> SupabaseProjectID {
        try SupabaseConfigFile.projectID(inConfigDirectory: configDirectory)
    }

    public var fingerprint: SupabaseLifecycleFingerprint {
        SupabaseLifecycleFingerprint(start: start, configDirectory: configDirectory)
    }

    /// 対象workdirの状態確認。実行結果の解釈は呼び出し側が行う。
    public var statusCommand: CommandSpec {
        CommandSpec(
            executable: start.executable,
            arguments: globalOptions
                + ["status", "--workdir", configDirectory.path, "--output", "json"],
            workingDirectory: configDirectory
        )
    }

    /// 対象`project_id`だけを停止するコマンド。他の停止方法は提供しない。
    public func stopCommand(projectID: SupabaseProjectID) -> CommandSpec {
        CommandSpec(
            executable: start.executable,
            arguments: globalOptions
                + ["stop", "--workdir", configDirectory.path, "--project-id", projectID.rawValue],
            workingDirectory: configDirectory
        )
    }
}
