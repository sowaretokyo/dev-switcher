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
        case .blue: "ブルー"
        case .purple: "パープル"
        case .pink: "ピンク"
        case .red: "レッド"
        case .orange: "オレンジ"
        case .yellow: "イエロー"
        case .green: "グリーン"
        case .teal: "ティール"
        }
    }
}

/// 古いPIDやポートを信用しないよう、保存対象に稼働状態を含めない。
/// `enabledNow`は「今回どれを起動するか」という設定であって、稼働している事実ではない。
public struct ProjectDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ProjectColor
    public var directory: URL
    /// 配列順が起動順。
    public var services: [ServiceDefinition]
    /// 既定の終了順（起動順の逆）を上書きするときだけ設定する。
    /// 設定する場合は全サービスIDを過不足なく含める必要があり、検証で保証する。
    public var stopOrder: [UUID]?
    /// 今回の起動対象。未設定のサービスは`enabledByDefault`に従う。
    public var enabledNow: [UUID: Bool]

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProjectColor,
        directory: URL,
        services: [ServiceDefinition],
        stopOrder: [UUID]? = nil,
        enabledNow: [UUID: Bool] = [:]
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.directory = directory
        self.services = services
        self.stopOrder = stopOrder
        self.enabledNow = enabledNow
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
        return stopOrder.compactMap { service(id: $0) }
    }

    /// 今回そのサービスを起動するか。`enabledNow`が未設定なら`enabledByDefault`に従う。
    public func isEnabledNow(_ serviceID: UUID) -> Bool {
        if let explicit = enabledNow[serviceID] { return explicit }
        return service(id: serviceID)?.enabledByDefault ?? false
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case directory
        case services
        case stopOrder
        case enabledNow
    }

    /// `[UUID: Bool]`をそのままエンコードするとJSONが配列になり、人が読めなくなる。
    /// キーをUUID文字列へ明示変換し、解釈できないキーは既定値へ倒さずエラーにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(ProjectColor.self, forKey: .color)
        directory = try container.decode(URL.self, forKey: .directory)
        services = try container.decode([ServiceDefinition].self, forKey: .services)
        stopOrder = try container.decodeIfPresent([UUID].self, forKey: .stopOrder)

        let rawEnabledNow = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .enabledNow
        ) ?? [:]
        var parsed: [UUID: Bool] = [:]
        for (key, value) in rawEnabledNow {
            guard let serviceID = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .enabledNow,
                    in: container,
                    debugDescription: "起動対象のキー「\(key)」をサービス ID として解釈できません。"
                )
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
        try container.encode(directory, forKey: .directory)
        try container.encode(services, forKey: .services)
        try container.encodeIfPresent(stopOrder, forKey: .stopOrder)
        let rawEnabledNow = Dictionary(
            uniqueKeysWithValues: enabledNow.map { ($0.key.uuidString, $0.value) }
        )
        try container.encode(rawEnabledNow, forKey: .enabledNow)
    }
}
