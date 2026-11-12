import Foundation

struct JSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Decoder {
    func rejectUnknownKeys(_ allowed: [String]) throws {
        let container = try self.container(keyedBy: JSONKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "未知のキー: \(unknown.joined(separator: ", "))"))
        }
    }
}

extension KeyedDecodingContainer {
    func optional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}
