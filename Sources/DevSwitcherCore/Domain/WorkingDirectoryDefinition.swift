import Foundation

/// 同じ作業ディレクトリから起動するプロセスを、利用者が付けた名前でまとめる。
///
/// Git リポジトリかどうかは判定しない。別リポジトリ、モノレポのサブディレクトリ、
/// 通常のローカルディレクトリを同じ構造で扱う。
public struct WorkingDirectoryDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var directory: URL
    /// このディレクトリに属するプロセス。プロセス本体と起動順は開発環境が持つ。
    public var serviceIDs: [UUID]
    public var stackIDs: [UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        directory: URL,
        serviceIDs: [UUID],
        stackIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.serviceIDs = serviceIDs
        self.stackIDs = stackIDs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, name, directory, serviceIDs, stackIDs }
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(URL.self, forKey: .directory)
        serviceIDs = try c.decode([UUID].self, forKey: .serviceIDs)
        stackIDs = try c.decode([UUID].self, forKey: .stackIDs)
    }
}
