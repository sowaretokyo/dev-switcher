import Foundation

public enum ComposeConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(reason): reason
        }
    }
}

/// 名前は明示値を変換しない。ディレクトリ名から導出するときだけ正規化する。
public struct ComposeProjectName: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let first = rawValue.utf8.first,
              Self.isLowercaseOrDigit(first),
              rawValue.utf8.allSatisfy({ Self.isLowercaseOrDigit($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        self.rawValue = rawValue
    }

    public static func fromDirectory(_ directory: URL) throws -> Self {
        let value = directory.lastPathComponent.lowercased().utf8.filter {
            isLowercaseOrDigit($0) || $0 == 45 || $0 == 95
        }
        guard let name = Self(rawValue: String(decoding: value, as: UTF8.self)) else {
            throw ComposeConfigurationError.invalid(
                L10n.text("ディレクトリ名から Compose のプロジェクト名を決められません。projectName を明示してください。")
            )
        }
        return name
    }

    private static func isLowercaseOrDigit(_ value: UInt8) -> Bool {
        (97...122).contains(value) || (48...57).contains(value)
    }
}

/// 親ディレクトリや環境変数へ探索を広げず、使用する全ファイルを確定する。
public enum ComposeFileLocator {
    public static func locate(files: [String]?, workingDirectory: URL) throws -> [URL] {
        guard workingDirectory.isFileURL, workingDirectory.path.hasPrefix("/") else {
            throw ComposeConfigurationError.invalid(L10n.text("Compose の作業ディレクトリは絶対パスで指定してください。"))
        }
        if let files {
            guard !files.isEmpty else {
                throw ComposeConfigurationError.invalid(L10n.text("Compose の files は1件以上指定してください。"))
            }
            return try files.map { path in
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0") else {
                    throw ComposeConfigurationError.invalid(L10n.text("Compose ファイルは空でない相対パスで指定してください（\(path)）。"))
                }
                return try checkedFile(workingDirectory.appendingPathComponent(path).standardizedFileURL)
            }
        }

        let families = [
            (["compose.yaml", "compose.yml"], ["compose.override.yaml", "compose.override.yml"]),
            (["docker-compose.yaml", "docker-compose.yml"], ["docker-compose.override.yaml", "docker-compose.override.yml"]),
        ]
        for (bases, overrides) in families {
            for base in bases {
                let url = workingDirectory.appendingPathComponent(base)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var result = [try checkedFile(url)]
                if let extra = overrides.map({ workingDirectory.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    result.append(try checkedFile(extra))
                }
                return result
            }
        }
        throw ComposeConfigurationError.invalid(L10n.text("作業ディレクトリ直下に Compose ファイルがありません。files を明示してください。"))
    }

    static func checkedFile(_ url: URL) throws -> URL {
        // 明示したパスや symlink からも、環境設定ファイルを読み取らない。
        for candidate in [url, url.resolvingSymlinksInPath()] {
            let name = candidate.lastPathComponent
            guard name != ".env", name != ".envrc", !name.hasPrefix(".env.") else {
                throw ComposeConfigurationError.invalid(L10n.text("環境設定ファイルを Compose ファイルとして読むことはできません。"))
            }
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else {
                throw ComposeConfigurationError.invalid(L10n.text("Compose ファイルを読み取れません（\(url.path)）。"))
            }
        } catch let error as ComposeConfigurationError {
            throw error
        } catch {
            throw ComposeConfigurationError.invalid(L10n.text("Compose ファイルを読み取れません（\(url.path)）。\n\(error)"))
        }
        return url.standardizedFileURL
    }
}

/// YAML 全体は解釈せず、トップレベルの単純な name: だけを受け付ける。
public enum ComposeProjectNameReader {
    public static func resolve(explicit: String?, files: [URL]) throws -> ComposeProjectName {
        guard let first = files.first else {
            throw ComposeConfigurationError.invalid(L10n.text("Compose ファイルが指定されていません。"))
        }
        if let explicit {
            return try validated(explicit)
        }
        var names: [String] = []
        for file in files {
            _ = try ComposeFileLocator.checkedFile(file)
            let text: String
            do {
                text = try String(contentsOf: file, encoding: .utf8)
            } catch {
                throw ComposeConfigurationError.invalid(L10n.text("Compose ファイルを UTF-8 として読めません（\(file.path)）。\n\(error)"))
            }
            if let name = try read(text) { names.append(name) }
        }
        guard Set(names).count <= 1 else {
            throw ComposeConfigurationError.invalid(L10n.text("Compose ファイル間で name: が異なります。projectName を明示してください。"))
        }
        if let name = names.first { return try validated(name) }
        return try ComposeProjectName.fromDirectory(first.deletingLastPathComponent())
    }

    static func read(_ text: String) throws -> String? {
        var found: String?
        var documentCount = 0
        var rootIndent: Int?
        var sawContent = false
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" {
                documentCount += 1
                guard documentCount <= 1, !sawContent else { throw unreadableName() }
                continue
            }
            let leading = line.prefix(while: { $0.isWhitespace })
            guard !leading.contains("\t") else { throw unreadableName() }
            if rootIndent == nil { rootIndent = leading.count }
            if leading.count > rootIndent! { continue }
            guard leading.count == rootIndent! else { throw unreadableName() }
            sawContent = true
            // フロー形式・複合キー・merge key は name: の有無を保証できない。
            if ["{", "[", "?", "<<:"].contains(where: trimmed.hasPrefix) { throw unreadableName() }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard ["name", "\"name\"", "'name'"].contains(key) else {
                if key.hasPrefix("\"") && key.contains("\\") { throw unreadableName() }
                continue
            }
            guard found == nil else { throw unreadableName() }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            found = try scalar(value)
        }
        return found
    }

    private static func scalar(_ source: String) throws -> String {
        guard !source.isEmpty else { throw unreadableName() }
        let value: String
        if let quote = source.first, quote == "\"" || quote == "'" {
            let rest = source.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { throw unreadableName() }
            value = String(rest[..<end])
            let suffix = rest[rest.index(after: end)...]
            guard suffix.isEmpty || (suffix.first?.isWhitespace == true && suffix.trimmingCharacters(in: .whitespaces).hasPrefix("#")) else {
                throw unreadableName()
            }
            guard !value.contains("\\") else { throw unreadableName() }
        } else {
            let chars = Array(source)
            let comment = chars.indices.first { chars[$0] == "#" && ($0 == 0 || chars[$0 - 1].isWhitespace) }
            value = String(chars[..<(comment ?? chars.endIndex)]).trimmingCharacters(in: .whitespaces)
        }
        guard !value.contains("${"), ComposeProjectName(rawValue: value) != nil else { throw unreadableName() }
        return value
    }

    private static func validated(_ value: String) throws -> ComposeProjectName {
        guard let name = ComposeProjectName(rawValue: value) else {
            throw ComposeConfigurationError.invalid(L10n.text("Compose のプロジェクト名「\(value)」は不正です。英小文字または数字で始まる英小文字・数字・-・_で指定してください。"))
        }
        return name
    }

    private static func unreadableName() -> ComposeConfigurationError {
        .invalid(L10n.text("Compose の name: を一意な名前として解釈できません。projectName を明示してください。"))
    }
}
