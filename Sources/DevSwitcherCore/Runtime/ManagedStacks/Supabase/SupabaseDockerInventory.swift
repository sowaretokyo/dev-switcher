import Foundation

/// Dockerから読み取った、1スタック分のコンテナ観測。
/// 実測状態そのものではなく、`supabase status`と組み合わせる前の材料。
public enum SupabaseContainerObservation: Equatable, Sendable {
    /// DBコンテナがrunningかつhealthy。
    case databaseHealthy
    /// コンテナは1件以上あるが、DBの欠損・停止・unhealthyを確認できた。
    case degraded(reason: String)
    /// ラベル欠落、DB候補の重複、未対応の状態。停止中へ倒さない。
    case indeterminate(reason: String)
}

public enum SupabaseInventoryResult: Equatable, Sendable {
    /// Dockerを読めた。ラベル値ごとの観測結果。要素が無いIDはコンテナ0件。
    case observed([SupabaseProjectID: SupabaseContainerObservation])
    /// docker実行失敗、JSON解析失敗、ラベル欠落など。全スタックをunknownとして扱う。
    case unobservable(reason: String)
}

/// Dockerの読み取りだけを差し替え可能にする。実装は観測専用で、状態を変更しない。
public protocol SupabaseInventoryProbing: Sendable {
    func containers() async -> SupabaseInventoryResult
}

/// `docker inspect`から必要な項目だけを取り出した値。
public struct SupabaseContainerRecord: Equatable, Sendable {
    public let containerID: String
    public let name: String
    /// `com.supabase.cli.project`ラベルの生値。欠落はnil。
    public let projectLabel: String?
    /// `State.Status`。
    public let status: String
    /// `State.Health.Status`。healthcheckが無ければnil。
    public let health: String?

    public init(
        containerID: String,
        name: String,
        projectLabel: String?,
        status: String,
        health: String?
    ) {
        self.containerID = containerID
        self.name = name
        self.projectLabel = projectLabel
        self.status = status
        self.health = health
    }

    /// `docker inspect`の`Name`は先頭に`/`が付く。
    var normalizedName: String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }
}

/// Supabase CLI互換性の要になる知識を1か所へ閉じ込める。
/// ラベル名、DBコンテナの見分け方、JSONの読み方はここだけで変更する。
public enum SupabaseDockerContract {
    /// Supabase CLIがローカルスタックのコンテナへ付けるラベル。
    public static let projectLabel = "com.supabase.cli.project"
    /// DBコンテナの名前。`project_id`はラベル値から取り、名前からは切り出さない。
    public static let databaseContainerPrefix = "supabase_db_"

    /// コンテナ一覧を`project_id`ごとの観測結果へ分類する。
    ///
    /// ラベルが欠けている、または解釈できない値が混ざっている場合は、
    /// 一部だけ分類して残りを停止中へ倒さないよう、観測全体を失敗にする。
    public static func classify(_ records: [SupabaseContainerRecord]) -> SupabaseInventoryResult {
        var grouped: [SupabaseProjectID: [SupabaseContainerRecord]] = [:]
        for record in records {
            guard let rawLabel = record.projectLabel else {
                return .unobservable(
                    reason: L10n.text("コンテナ \(record.normalizedName) に `\(projectLabel)` ラベルがありません。")
                )
            }
            guard let projectID = SupabaseProjectID(rawValue: rawLabel) else {
                return .unobservable(
                    reason: L10n.text("コンテナ \(record.normalizedName) の `\(projectLabel)` ラベル「\(rawLabel)」を解釈できません。")
                )
            }
            grouped[projectID, default: []].append(record)
        }

        var result: [SupabaseProjectID: SupabaseContainerObservation] = [:]
        for (projectID, containers) in grouped {
            result[projectID] = observation(for: projectID, containers: containers)
        }
        return .observed(result)
    }

    private static func observation(
        for projectID: SupabaseProjectID,
        containers: [SupabaseContainerRecord]
    ) -> SupabaseContainerObservation {
        let databases = containers.filter {
            $0.normalizedName.hasPrefix(databaseContainerPrefix)
        }
        guard databases.count <= 1 else {
            return .indeterminate(
                reason: L10n.text("\(projectID) のDBコンテナ候補が複数あります（\(databases.map(\.normalizedName).sorted().joined(separator: ", "))）。")
            )
        }
        guard let database = databases.first else {
            return .degraded(
                reason: L10n.text("\(projectID) のコンテナは \(containers.count) 件ありますが、DBコンテナがありません。")
            )
        }

        switch database.status.lowercased() {
        case "running":
            switch database.health?.lowercased() {
            case "healthy":
                return .databaseHealthy
            case "unhealthy":
                return .degraded(reason: L10n.text("\(database.normalizedName) が unhealthy です。"))
            case "starting":
                return .indeterminate(reason: L10n.text("\(database.normalizedName) の health が starting です。"))
            case .none:
                return .indeterminate(
                    reason: L10n.text("\(database.normalizedName) に healthcheck の結果がありません。")
                )
            case let .some(other):
                return .indeterminate(
                    reason: L10n.text("\(database.normalizedName) の health「\(other)」は未対応です。")
                )
            }
        case "exited", "dead", "created", "paused", "removing":
            return .degraded(
                reason: L10n.text("\(database.normalizedName) が \(database.status) 状態です。")
            )
        case "restarting":
            return .indeterminate(reason: L10n.text("\(database.normalizedName) が restarting 中です。"))
        default:
            return .indeterminate(
                reason: L10n.text("\(database.normalizedName) の status「\(database.status)」は未対応です。")
            )
        }
    }

    /// `docker ps -a --format {{json .}}` の各行からコンテナIDを取り出す。
    public static func containerIDs(fromListOutput output: String) throws -> [String] {
        var ids: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw SupabaseInventoryError.decodingFailed(preview: String(trimmed.prefix(200)))
            }
            do {
                let entry = try JSONDecoder().decode(ListEntry.self, from: data)
                let id = entry.id.trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty else {
                    throw SupabaseInventoryError.decodingFailed(
                        preview: String(trimmed.prefix(200))
                    )
                }
                ids.append(id)
            } catch let error as SupabaseInventoryError {
                throw error
            } catch {
                throw SupabaseInventoryError.decodingFailed(preview: String(trimmed.prefix(200)))
            }
        }
        return ids
    }

    /// `docker inspect --format {{json .}}` の各行を必要な項目だけへ変換する。
    public static func records(fromInspectOutput output: String) throws -> [SupabaseContainerRecord] {
        var records: [SupabaseContainerRecord] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw SupabaseInventoryError.decodingFailed(preview: String(trimmed.prefix(200)))
            }
            let entry: InspectEntry
            do {
                entry = try JSONDecoder().decode(InspectEntry.self, from: data)
            } catch {
                throw SupabaseInventoryError.decodingFailed(preview: String(trimmed.prefix(200)))
            }
            guard let status = entry.state?.status else {
                throw SupabaseInventoryError.decodingFailed(preview: String(trimmed.prefix(200)))
            }
            records.append(
                SupabaseContainerRecord(
                    containerID: entry.id ?? "",
                    name: entry.name ?? "",
                    projectLabel: entry.config?.labels?[projectLabel],
                    status: status,
                    health: entry.state?.health?.status
                )
            )
        }
        return records
    }

    private struct ListEntry: Decodable {
        let id: String

        private enum CodingKeys: String, CodingKey {
            case id = "ID"
        }
    }

    private struct InspectEntry: Decodable {
        let id: String?
        let name: String?
        let config: ConfigSection?
        let state: StateSection?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case config = "Config"
            case state = "State"
        }

        struct ConfigSection: Decodable {
            let labels: [String: String]?

            private enum CodingKeys: String, CodingKey {
                case labels = "Labels"
            }
        }

        struct StateSection: Decodable {
            let status: String?
            let health: HealthSection?

            private enum CodingKeys: String, CodingKey {
                case status = "Status"
                case health = "Health"
            }
        }

        struct HealthSection: Decodable {
            let status: String?

            private enum CodingKeys: String, CodingKey {
                case status = "Status"
            }
        }
    }
}

public enum SupabaseInventoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case dockerUnavailable(reason: String)
    case commandFailed(command: String, status: ExitStatus, output: String)
    case decodingFailed(preview: String)

    public var description: String {
        switch self {
        case let .dockerUnavailable(reason):
            L10n.text("docker コマンドを実行できません。\n\(reason)")
        case let .commandFailed(command, status, output):
            output.isEmpty
                ? L10n.text("\(command) が失敗しました（\(status.description)）。")
                : L10n.text("\(command) が失敗しました（\(status.description)）。\n\(output)")
        case let .decodingFailed(preview):
            L10n.text("docker の出力を解釈できません。\n\(preview)")
        }
    }
}

/// `docker ps -a`と`docker inspect`だけを使うread-onlyのinventory。
/// `docker start`、`docker stop`、コンテナ削除、volume操作は実装しない。
public struct SupabaseDockerInventory: SupabaseInventoryProbing {
    public typealias EnvironmentProvider = @Sendable () async throws -> ShellEnvironment

    private let environmentProvider: EnvironmentProvider
    private let timeout: Duration

    public init(
        environmentProvider: @escaping EnvironmentProvider,
        timeout: Duration = .seconds(30)
    ) {
        self.environmentProvider = environmentProvider
        self.timeout = timeout
    }

    public func containers() async -> SupabaseInventoryResult {
        do {
            let environment = try await environmentProvider()
            let ids = try SupabaseDockerContract.containerIDs(
                fromListOutput: try await run(
                    arguments: [
                        "ps", "-a",
                        "--filter", "label=\(SupabaseDockerContract.projectLabel)",
                        "--no-trunc",
                        "--format", "{{json .}}",
                    ],
                    environment: environment
                )
            )
            guard !ids.isEmpty else { return .observed([:]) }

            let records = try SupabaseDockerContract.records(
                fromInspectOutput: try await run(
                    arguments: ["inspect", "--format", "{{json .}}"] + ids,
                    environment: environment
                )
            )
            return SupabaseDockerContract.classify(records)
        } catch {
            return .unobservable(reason: "\(error)")
        }
    }

    /// shell文字列を組み立てず、実行ファイルはGUI用PATHの解決結果だけを使う。
    private func run(arguments: [String], environment: ShellEnvironment) async throws -> String {
        let workingDirectory = URL(fileURLWithPath: "/")
        let resolved: ResolvedCommand
        do {
            resolved = try ExecutableResolver.resolve(
                CommandSpec(
                    executable: "docker",
                    arguments: arguments,
                    workingDirectory: workingDirectory
                ),
                searchPath: environment.searchPath
            )
        } catch {
            throw SupabaseInventoryError.dockerUnavailable(reason: "\(error)")
        }

        let result = try await CommandOutput.capture(
            executable: resolved.executableURL,
            arguments: resolved.arguments,
            environment: environment.variables,
            workingDirectory: resolved.workingDirectory,
            timeout: timeout
        )
        guard result.status.isSuccess else {
            throw SupabaseInventoryError.commandFailed(
                command: "docker \(arguments.prefix(2).joined(separator: " "))",
                status: result.status,
                output: result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutputText
    }
}
