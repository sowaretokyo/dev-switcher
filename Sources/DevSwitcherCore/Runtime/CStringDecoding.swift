import Darwin
import Foundation

/// C 文字列を Swift の String へ変換する。
///
/// `String(cString:)` は非推奨のうえ、NUL が無い入力で範囲外まで読む。
/// 常に NUL までで切り、UTF-8 として解釈する。
enum CStringDecoding {
    static func string(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func string(_ pointer: UnsafePointer<CChar>?, maximumLength: Int = 1024) -> String {
        guard let pointer else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for offset in 0..<maximumLength {
            let value = pointer[offset]
            if value == 0 { break }
            bytes.append(UInt8(bitPattern: value))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// errno の説明。`String(cString:)` を使わずに取り出す。
    static func errorMessage(_ code: Int32) -> String {
        CStringDecoding.string(strerror(code))
    }
}
