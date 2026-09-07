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

    public init(
        id: UUID = UUID(),
        name: String,
        directory: URL,
        serviceIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.serviceIDs = serviceIDs
    }
}
