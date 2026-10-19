import Foundation

// Supabase を管理対象スタックの 1 種類として扱うための設定・検証・ID 解決。
// Supabase CLI の呼び出し形式、`--workdir` の解決、禁止オプションの知識はこのファイルに閉じる。

/// ローカルSupabaseスタックの同一性。
///
/// Supabase CLIが同一マシン上のローカルプロジェクトを区別する値（`supabase/config.toml`の
/// `project_id`）だけを根拠にする。ディレクトリ名、コンテナ名、ポートからは補完しない。
public struct SupabaseProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Dockerのコンテナ名へ使える文字だけを受け付ける。
    /// `-`始まりを弾くのは、`--project-id`の値がフラグとして解釈されないようにするため。
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              let first = trimmed.first,
              first.isLetter || first.isNumber,
              trimmed.allSatisfy({ Self.allowedCharacters.contains($0) }) else {
            return nil
        }
        self.rawValue = trimmed
    }

    private static let allowedCharacters: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
    )

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = SupabaseProjectID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "project_id「\(raw)」を解釈できません。"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 種類共通のIDから戻す。種類が違う、または値が`project_id`の規則に合わなければ throw する。
    public init(identity: ManagedStackIdentity) throws {
        guard identity.type == .supabase else {
            throw ManagedStackIdentityError.typeMismatch(
                expected: .supabase,
                actual: identity.type
            )
        }
        guard let projectID = Self(exactRawValue: identity.value) else {
            throw ManagedStackIdentityError.invalidValue(type: .supabase, value: identity.value)
        }
        self = projectID
    }

    /// 正規化（前後の空白除去）で値が変わらない場合だけ作る。
    /// 種類共通のIDは生成後に正規化しないため、IDとの相互変換はこちらを使う。
    init?(exactRawValue value: String) {
        guard let projectID = Self(rawValue: value), projectID.rawValue == value else {
            return nil
        }
        self = projectID
    }
}

extension ManagedStackIdentity {
    /// `SupabaseProjectID`は検証済みの値なので、失敗しない。
    public init(_ projectID: SupabaseProjectID) {
        self.init(validatedType: .supabase, value: projectID.rawValue)
    }
}

/// 対象設定が保存時・確認時から変わっていないかを、ハッシュ衝突なしで照合する値。
public struct SupabaseLifecycleFingerprint: Codable, Equatable, Sendable {
    public let executable: String
    public let startArguments: [String]
    public let startWorkingDirectory: URL
    public let configDirectory: URL

    public init(start: CommandSpec, configDirectory: URL) {
        executable = start.executable
        startArguments = start.arguments
        startWorkingDirectory = start.workingDirectory.standardizedFileURL
        self.configDirectory = configDirectory.standardizedFileURL
    }

    public var displayCommandLine: String {
        ([executable] + startArguments).joined(separator: " ")
    }
}

/// Supabaseスタックの設定。v3では`kind: "supabase"`のサービスの`start`と`stop`から作る。
///
/// `stop`はv3の形式に合わせて保持するだけで、指定されていれば構造不備として扱う。
/// 停止は常に起動コマンドと同じCLIから導出する。
public struct SupabaseStackConfiguration: Equatable, Sendable {
    public var start: CommandSpec
    public var stop: CommandSpec?

    public init(start: CommandSpec, stop: CommandSpec? = nil) {
        self.start = start
        self.stop = stop
    }

    /// 複数プロジェクトやバックアップを巻き込むため、どの経路でも受け付けない。
    static let forbiddenStopOptions: Set<String> = ["--all", "--no-backup"]

    /// ファイルを読まずに判定できる設定の不備。現行の優先順位で最初の1件だけを返す。
    public func structuralIssues(workingDirectory: URL) -> [SupabaseConfigurationIssue] {
        switch derivation(workingDirectory: workingDirectory) {
        case .derived: []
        case let .invalid(issue): [issue]
        }
    }

    /// Supabase CLIの起動コマンドから、設定ディレクトリと派生コマンドを構造化して導出する。
    /// 導出できない形式は既定へ倒さず nil を返し、呼び出し側が起動前に失敗させる。
    public func derived(workingDirectory: URL) -> SupabaseDerivedConfiguration? {
        switch derivation(workingDirectory: workingDirectory) {
        case let .derived(configuration): configuration
        case .invalid: nil
        }
    }

    /// 設定ファイルから`project_id`を読み、IDと構成同一性を確定する。
    /// 構造不備は`ManagedStackConfigurationError`、設定ファイルの読み取りエラーは
    /// `SupabaseConfigError`をそのまま throw する。
    public func resolve(workingDirectory: URL) throws -> SupabaseResolvedConfiguration {
        let derived: SupabaseDerivedConfiguration
        switch derivation(workingDirectory: workingDirectory) {
        case let .derived(value):
            derived = value
        case let .invalid(issue):
            throw ManagedStackConfigurationError.invalid(.supabase(issue))
        }
        let projectID = try derived.resolveProjectID()
        return SupabaseResolvedConfiguration(derived: derived, projectID: projectID)
    }

    /// 導出の結果。導出できたか、最初に見つかった構造不備のどちらか一方だけを持つ。
    private enum Derivation {
        case derived(SupabaseDerivedConfiguration)
        case invalid(SupabaseConfigurationIssue)
    }

    /// 構造不備の判定と導出を 1 か所で行う。`structuralIssues`と`derived`はこの射影なので、
    /// 両者の判定がずれることはない。
    /// 判定順（優先順位）: stop → 呼び出し形式 → startサブコマンド → 禁止オプション → workdir。
    private func derivation(workingDirectory: URL) -> Derivation {
        if stop != nil {
            return .invalid(.customStopUnsupported)
        }
        if !hasSupportedInvocation {
            return .invalid(.commandUnsupported)
        }
        guard let startIndex = startSubcommandIndex else {
            return .invalid(.startSubcommandMissing)
        }
        if let forbidden = Self.forbiddenStopOptions
            .sorted()
            .first(where: start.arguments.contains) {
            return .invalid(.forbiddenStopOption(forbidden))
        }
        guard let workdir = workdirArgument() else {
            return .invalid(.workdirValueMissing)
        }
        let configDirectory = workdir.map { value -> URL in
            value.hasPrefix("/")
                ? URL(fileURLWithPath: value).standardizedFileURL
                : workingDirectory.appendingPathComponent(value).standardizedFileURL
        } ?? workingDirectory.standardizedFileURL

        return .derived(SupabaseDerivedConfiguration(
            start: start,
            globalOptions: Self.derivedGlobalOptions(Array(start.arguments[..<startIndex])),
            configDirectory: configDirectory
        ))
    }

    /// ラッパーの任意の`start`をSupabaseサブコマンドと誤認しないため、
    /// 実行ファイルとパッケージ位置を特定できる形式だけを受け付ける。
    private var hasSupportedInvocation: Bool {
        subcommandStartIndex != nil
    }

    /// `--workdir`はグローバルオプションで、サブコマンドの前後どちらにも置ける。
    /// 戻り値の`nil`は値の欠落による導出失敗、`.some(nil)`は「指定なし」。
    private func workdirArgument() -> String?? {
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

    private var startSubcommandIndex: Int? {
        guard var index = subcommandStartIndex else { return nil }

        while index < start.arguments.count {
            let argument = start.arguments[index]
            if argument == "start" { return index }

            if Self.booleanGlobalOptions.contains(argument) {
                index += 1
                continue
            }
            if Self.valueGlobalOptions.contains(argument) {
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
               Self.valueGlobalOptions.contains(String(argument[..<separator])),
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
    private var subcommandStartIndex: Int? {
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

    private static let booleanGlobalOptions: Set<String> = [
        "--create-ticket", "--debug", "--experimental", "--yes",
    ]

    private static let valueGlobalOptions: Set<String> = [
        "--dns-resolver", "--network-id", "--output", "--profile", "--workdir", "-o",
    ]

    /// `project_id`として受け付ける値か。正規化（前後の空白除去）で値が変わるものも拒否する。
    static func isValidIdentityValue(_ value: String) -> Bool {
        SupabaseProjectID(exactRawValue: value) != nil
    }
}

/// ファイルを読まずに判定できるSupabase設定の不備。
public enum SupabaseConfigurationIssue: Equatable, Sendable {
    /// v3の`stop`が指定されている。停止は起動コマンドから導出する。
    case customStopUnsupported
    /// 対応していない呼び出し形式。
    case commandUnsupported
    /// `start`サブコマンドが無い。
    case startSubcommandMissing
    /// 起動コマンドに禁止オプションがある。値は最初に見つかったもの（辞書順）。
    case forbiddenStopOption(String)
    /// `--workdir`の値が欠けている。
    case workdirValueMissing

    /// 起動・切替・手掛かりの再検証で示す理由。
    public var failureReason: String {
        switch self {
        case .customStopUnsupported:
            "Supabaseの終了コマンドは起動コマンドから導出するため、個別には指定できません。"
        case .commandUnsupported:
            "起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
        case .startSubcommandMissing:
            "起動コマンドに `start` サブコマンドがありません。"
        case .forbiddenStopOption:
            "起動コマンドに `--all` と `--no-backup` は指定できません。"
        case .workdirValueMissing:
            "`--workdir` にディレクトリが指定されていません。"
        }
    }

    /// 保存・取り込み時の検証で示す文言。
    public func validationMessage(stackName: String) -> String {
        switch self {
        case .customStopUnsupported:
            "Supabase「\(stackName)」の終了コマンドは個別に指定できません。起動コマンドから導出した `supabase stop` を使用します。"
        case .commandUnsupported:
            "Supabase「\(stackName)」の起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
        case .startSubcommandMissing:
            "Supabase「\(stackName)」の起動コマンドに `start` サブコマンドがありません。"
        case let .forbiddenStopOption(option):
            "Supabase「\(stackName)」の起動コマンドに `\(option)` は指定できません。複数プロジェクトやバックアップを巻き込むため、Dev Switcherでは実行しません。"
        case .workdirValueMissing:
            "Supabase「\(stackName)」の `--workdir` にディレクトリが指定されていません。"
        }
    }
}

/// Supabaseスタックのlifecycleコマンドを組み立てる。
///
/// 生成できるのは`status`と、`--project-id`で対象を限定した`stop`だけ。
/// `--all`、`--no-backup`、任意の停止コマンドを表現できる入口を持たない。
public struct SupabaseDerivedConfiguration: Equatable, Sendable {
    public let start: CommandSpec
    /// `start`より前に置かれたグローバル引数。`--workdir`と`--output`は含まない。
    private let globalOptions: [String]
    /// `project_id`を読む基準ディレクトリ。`--workdir`があればその値。
    public let configDirectory: URL

    init(
        start: CommandSpec,
        globalOptions: [String],
        configDirectory: URL
    ) {
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

/// `project_id`まで確定したSupabaseの設定。
public struct SupabaseResolvedConfiguration: Equatable, Sendable {
    public let derived: SupabaseDerivedConfiguration
    public let projectID: SupabaseProjectID

    /// テストで設定ファイルを読まずに作るための口。通常は`SupabaseStackConfiguration.resolve`で作る。
    init(derived: SupabaseDerivedConfiguration, projectID: SupabaseProjectID) {
        self.derived = derived
        self.projectID = projectID
    }

    public var identity: ManagedStackIdentity {
        ManagedStackIdentity(projectID)
    }

    public var fingerprint: SupabaseLifecycleFingerprint {
        derived.fingerprint
    }
}
