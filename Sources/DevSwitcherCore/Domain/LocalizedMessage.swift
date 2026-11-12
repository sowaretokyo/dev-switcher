import Foundation
import Synchronization

/// 翻訳キーと動的な値を分離する。利用者入力をキーとして検索・再翻訳しない。
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public let key: String
    public let arguments: [String]

    public init(key: String, arguments: [String]) {
        self.key = key
        self.arguments = arguments
    }

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { key += literal }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }

    /// 置換した引数の中に {0} があっても再解釈しない。
    public func rendered(using template: String) -> String {
        let source = template as NSString
        var result = ""
        var offset = 0
        var used = Set<Int>()
        for match in Self.placeholderPattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            guard let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) else {
                preconditionFailure("Invalid localization placeholder: \(key)")
            }
            result += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            result += arguments[index]
            used.insert(index)
            offset = NSMaxRange(match.range)
        }
        precondition(used == Set(arguments.indices), "Missing localization argument: \(key)")
        result += source.substring(from: offset)
        return result
    }
}

/// Core は翻訳リソースを所有しない。アプリが起動時に表示用 renderer を設定する。
/// 単独の Core 利用・既存の単体テストでは、日本語の原文を診断表示に使う。
/// OS の言語変更はアプリの次回起動から反映する。
public enum L10n {
    public typealias Renderer = @Sendable (LocalizedMessage) -> String
    private static let renderer = Mutex<Renderer?>(nil)
    @TaskLocal public static var override: Renderer?

    public static func install(_ render: @escaping Renderer) {
        renderer.withLock { current in
            precondition(current == nil, "Localization must be installed once at app startup.")
            current = render
        }
    }

    public static func text(_ message: LocalizedMessage) -> String {
        if let render = override ?? renderer.withLock({ $0 }) { return render(message) }
        return message.rendered(using: message.key)
    }
}
