import Foundation

/// `timestamp` と `id` は書き込み時ではなく読み取り時の値。
/// 別ファイルに残したstdoutとstderrの厳密な相対順序は復元できない。
public struct LogLine: Identifiable, Equatable, Sendable {
    public enum Stream: String, Equatable, Hashable, Sendable {
        case stdout
        case stderr
    }

    public let id: UInt64
    public let timestamp: Date
    public let stream: Stream
    public let text: String

    public init(id: UInt64, timestamp: Date, stream: Stream, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }
}
