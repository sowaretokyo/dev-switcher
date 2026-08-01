import Foundation

/// 設定値と実際に listen しているポートを混同しないため、`ObservedPort` とは別の型で持つ。
public struct PortSpec: Codable, Equatable, Sendable, Identifiable {
    public static let validRange = 1...65_535

    public var id: UUID
    public var label: String?
    public var port: Int
    /// ポートを持つサービスでは、必ず1件だけを代表にする。
    public var isPrimary: Bool
    public var openURL: String?

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        port: Int,
        isPrimary: Bool,
        openURL: String? = nil
    ) {
        self.id = id
        self.label = label
        self.port = port
        self.isPrimary = isPrimary
        self.openURL = openURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case port
        case isPrimary = "primary"
        case openURL = "openUrl"
    }

    public var displayName: String {
        if let label, !label.isEmpty {
            return "\(label) :\(port)"
        }
        return ":\(port)"
    }
}
