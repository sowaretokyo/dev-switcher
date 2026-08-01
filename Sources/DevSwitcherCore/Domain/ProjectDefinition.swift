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
public struct ProjectDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ProjectColor
    public var directory: URL
    public var services: [ServiceDefinition]

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProjectColor,
        directory: URL,
        services: [ServiceDefinition]
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.directory = directory
        self.services = services
    }

    /// 名前から再現できる表示値なので保存しない。
    public var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    public func service(id serviceID: UUID) -> ServiceDefinition? {
        services.first { $0.id == serviceID }
    }
}
