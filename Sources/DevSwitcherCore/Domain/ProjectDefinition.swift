import Foundation

/// 状態色と混同しないよう、プロジェクト識別色を専用の型で制限する。
public enum ProjectColor: String, Codable, Sendable, CaseIterable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal

    public var displayName: String {
        switch self {
        case .blue: L10n.text("ブルー")
        case .purple: L10n.text("パープル")
        case .pink: L10n.text("ピンク")
        case .red: L10n.text("レッド")
        case .orange: L10n.text("オレンジ")
        case .yellow: L10n.text("イエロー")
        case .green: L10n.text("グリーン")
        case .teal: L10n.text("ティール")
        }
    }
}

/// 古いPIDやポートを信用しないよう、保存対象に稼働状態を含めない。
/// `enabledNow`は「今回どれを起動するか」という設定であって、稼働している事実ではない。
public struct ProjectDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ProjectColor
    /// 利用者が名前を付けた作業ディレクトリ。Git リポジトリとは限らない。
    public var workingDirectories: [WorkingDirectoryDefinition]
    /// 配列順が起動順。
    public var services: [ServiceDefinition]
    public var managedStacks: [ManagedStackDefinition]
    /// 旧形式から順序が変わった場合に、次の保存まで表示する。保存しない。
    public var migrationNotice: String?
    /// 既定の終了順（起動順の逆）を上書きするときだけ設定する。
    /// 設定する場合は全サービスIDを過不足なく含める必要があり、検証で保証する。
    public var stopOrder: [UUID]?
    /// 今回の起動対象。未設定のサービスは`enabledByDefault`に従う。
    public var enabledNow: [UUID: Bool]

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProjectColor,
        workingDirectories: [WorkingDirectoryDefinition],
        services: [ServiceDefinition],
        managedStacks: [ManagedStackDefinition] = [],
        stopOrder: [UUID]? = nil,
        enabledNow: [UUID: Bool] = [:]
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.workingDirectories = workingDirectories
        self.services = services
        self.managedStacks = managedStacks
        self.migrationNotice = nil
        self.stopOrder = stopOrder
        self.enabledNow = enabledNow
    }

    /// schema v1/v2 と既存のコードから、サービスの作業パスごとに明示的なグループを作る。
    /// サービスの配列順は起動順なので、グループ化しても並べ替えない。
    init(
        id: UUID = UUID(),
        name: String,
        color: ProjectColor,
        directory: URL,
        services: [ServiceDefinition],
        managedStacks: [ManagedStackDefinition] = [],
        stopOrder: [UUID]? = nil,
        enabledNow: [UUID: Bool] = [:]
    ) {
        self.init(
            id: id,
            name: name,
            color: color,
            workingDirectories: Self.groupedWorkingDirectories(
                services: services,
                fallbackDirectory: directory
            ),
            services: services,
            managedStacks: managedStacks,
            stopOrder: stopOrder,
            enabledNow: enabledNow
        )
    }

    /// 名前から再現できる表示値なので保存しない。
    public var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    public func service(id serviceID: UUID) -> ServiceDefinition? {
        services.first { $0.id == serviceID }
    }

    // MARK: - 起動順・終了順・起動対象

    /// 起動順。配列順そのもの。
    public var startupOrder: [ServiceDefinition] { services }

    /// 終了順。既定は起動順の逆。`stopOrder`があればそれに従う。
    /// 未知のIDや欠落は検証で拒否済みのため、ここでは補完しない。
    public var shutdownOrder: [ServiceDefinition] {
        guard let stopOrder else { return services.reversed() }
        return stopOrder.map { serviceID in
            guard let service = service(id: serviceID) else {
                preconditionFailure(L10n.text("終了順に存在しないプロセス ID が含まれています。"))
            }
            return service
        }
    }

    /// 今回そのサービスを起動するか。`enabledNow`が未設定なら`enabledByDefault`に従う。
    public func isEnabledNow(_ serviceID: UUID) -> Bool {
        guard let unit = entry(id: serviceID) else {
            preconditionFailure(L10n.text("存在しないプロセス・スタックの起動対象は取得できません。"))
        }
        return enabledNow[serviceID] ?? unit.enabledByDefault
    }

    /// 今回起動するサービスを起動順で返す。
    public var enabledStartupOrder: [ServiceDefinition] {
        startupOrder.filter { isEnabledNow($0.id) }
    }

    /// 今回起動しないサービス。「対象外」として表示し、一部停止や失敗に含めない。
    public var excludedServices: [ServiceDefinition] {
        services.filter { !isEnabledNow($0.id) }
    }

    /// 起動対象を明示的に切り替えた新しい定義を返す。
    public func settingEnabledNow(_ serviceID: UUID, to enabled: Bool) -> ProjectDefinition {
        var updated = self
        updated.enabledNow[serviceID] = enabled
        return updated
    }

    /// 「既定に戻す」。明示指定を消して`enabledByDefault`に従わせる。
    public func clearingEnabledNow() -> ProjectDefinition {
        var updated = self
        updated.enabledNow = [:]
        return updated
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case color
        case workingDirectories
        case services
        case managedStacks
        case stopOrder
        case enabledNow
    }

    /// `[UUID: Bool]`をそのままエンコードするとJSONが配列になり、人が読めなくなる。
    /// キーをUUID文字列へ明示変換し、解釈できないキーは既定値へ倒さずエラーにする。
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(ProjectColor.self, forKey: .color)
        workingDirectories = try container.decode(
            [WorkingDirectoryDefinition].self,
            forKey: .workingDirectories
        )
        services = try container.decode([ServiceDefinition].self, forKey: .services)
        managedStacks = try container.decode([ManagedStackDefinition].self, forKey: .managedStacks)
        migrationNotice = nil
        stopOrder = try container.optional([UUID].self, forKey: .stopOrder)

        let rawEnabledNow = try container.optional(
            [String: Bool].self,
            forKey: .enabledNow
        ) ?? [:]
        var parsed: [UUID: Bool] = [:]
        for (key, value) in rawEnabledNow {
            guard let serviceID = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .enabledNow,
                    in: container,
                    debugDescription: L10n.text("起動対象のキー「\(key)」をサービス ID として解釈できません。")
                )
            }
            guard parsed[serviceID] == nil else {
                throw DecodingError.dataCorruptedError(forKey: .enabledNow, in: container, debugDescription: L10n.text("起動対象の ID が重複しています。"))
            }
            parsed[serviceID] = value
        }
        enabledNow = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(workingDirectories, forKey: .workingDirectories)
        try container.encode(services, forKey: .services)
        try container.encode(managedStacks, forKey: .managedStacks)
        try container.encodeIfPresent(stopOrder, forKey: .stopOrder)
        let rawEnabledNow = Dictionary(
            uniqueKeysWithValues: enabledNow.map { ($0.key.uuidString, $0.value) }
        )
        try container.encode(rawEnabledNow, forKey: .enabledNow)
    }

    /// 旧形式では作業ディレクトリ名が無いため、パス末尾を移行後の表示名にする。
    /// 同じ末尾名が複数ある場合だけ番号を付け、名前重複による読み込み失敗を避ける。
    private static func groupedWorkingDirectories(
        services: [ServiceDefinition],
        managedStacks: [ManagedStackDefinition] = [],
        fallbackDirectory: URL
    ) -> [WorkingDirectoryDefinition] {
        guard !services.isEmpty else {
            return [
                WorkingDirectoryDefinition(
                    name: suggestedDirectoryName(fallbackDirectory),
                    directory: fallbackDirectory,
                    serviceIDs: []
                )
            ]
        }

        var groups: [WorkingDirectoryDefinition] = []
        var indexByPath: [String: Int] = [:]
        var usedNames: Set<String> = []

        for service in services {
            let directory = service.start.workingDirectory.standardizedFileURL
            let path = directory.path
            if let index = indexByPath[path] {
                groups[index].serviceIDs.append(service.id)
                continue
            }

            let baseName = suggestedDirectoryName(directory)
            var uniqueName = baseName
            var suffix = 2
            while usedNames.contains(uniqueName.lowercased()) {
                uniqueName = "\(baseName) \(suffix)"
                suffix += 1
            }
            usedNames.insert(uniqueName.lowercased())
            indexByPath[path] = groups.count
            groups.append(
                WorkingDirectoryDefinition(
                    name: uniqueName,
                    directory: directory,
                    serviceIDs: [service.id]
                )
            )
        }
        return groups
    }

    private static func suggestedDirectoryName(_ directory: URL) -> String {
        let lastComponent = directory.standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastComponent.isEmpty ? directory.path : lastComponent
    }
}
