import Foundation

public enum SupabaseConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileMissing(URL)
    case unreadable(URL, reason: String)
    case projectIDMissing(URL)
    case projectIDEmpty(URL)
    case projectIDDuplicated(URL)
    case projectIDUnparsable(URL, line: String)
    case projectIDUnsupportedValue(URL, value: String)

    public var description: String {
        switch self {
        case let .fileMissing(url):
            L10n.text("Supabaseの設定ファイルがありません（\(url.path)）。")
        case let .unreadable(url, reason):
            L10n.text("Supabaseの設定ファイルを読めません（\(url.path)）。\n\(reason)")
        case let .projectIDMissing(url):
            L10n.text("Supabaseの設定ファイルにトップレベルの `project_id` がありません（\(url.path)）。")
        case let .projectIDEmpty(url):
            L10n.text("Supabaseの設定ファイルの `project_id` が空です（\(url.path)）。")
        case let .projectIDDuplicated(url):
            L10n.text("Supabaseの設定ファイルにトップレベルの `project_id` が複数あります（\(url.path)）。")
        case let .projectIDUnparsable(url, line):
            L10n.text("Supabaseの設定ファイルの `project_id` を解釈できません（\(url.path)）。\n該当行: \(line)")
        case let .projectIDUnsupportedValue(url, value):
            L10n.text("Supabaseの `project_id`「\(value)」は英数字で始まり、英数字・`_`・`.`・`-` だけで構成してください（\(url.path)）。")
        }
    }
}

/// `supabase/config.toml` から`project_id`だけを読む専用parser。
///
/// 外部パッケージを増やさないため、TOML全体は解釈しない。読むのは
/// トップレベル（最初のテーブル見出しより前）の`project_id`だけで、
/// コメント内や別sectionの同名キーは対象にしない。
public enum SupabaseConfigFile {
    /// 設定ディレクトリからの相対位置。CLIの規約に合わせる。
    public static let relativeComponents = ["supabase", "config.toml"]

    public static func configFileURL(inConfigDirectory directory: URL) -> URL {
        relativeComponents.reduce(directory.standardizedFileURL) {
            $0.appendingPathComponent($1)
        }
    }

    /// 設定ディレクトリ配下の`supabase/config.toml`から`project_id`を取得する。
    public static func projectID(inConfigDirectory directory: URL) throws -> SupabaseProjectID {
        let url = configFileURL(inConfigDirectory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SupabaseConfigError.fileMissing(url)
        }
        let text: String
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw SupabaseConfigError.unreadable(
                    url,
                    reason: L10n.text("UTF-8として解釈できません。")
                )
            }
            text = decoded
        } catch let error as SupabaseConfigError {
            throw error
        } catch {
            throw SupabaseConfigError.unreadable(url, reason: "\(error)")
        }
        return try projectID(inConfigText: text, source: url)
    }

    /// ファイル読み込みと分離して検証できるよう、本文の解析だけを切り出す。
    public static func projectID(
        inConfigText text: String,
        source url: URL
    ) throws -> SupabaseProjectID {
        var found: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // テーブル見出しより後ろはトップレベルではない。別sectionの同名キーは読まない。
            if line.hasPrefix("[") { break }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "project_id" else { continue }

            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard let value = quotedValue(rawValue) else {
                throw SupabaseConfigError.projectIDUnparsable(url, line: line)
            }
            guard found == nil else {
                throw SupabaseConfigError.projectIDDuplicated(url)
            }
            found = value
        }

        guard let found else { throw SupabaseConfigError.projectIDMissing(url) }
        guard !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseConfigError.projectIDEmpty(url)
        }
        guard let projectID = SupabaseProjectID(rawValue: found) else {
            throw SupabaseConfigError.projectIDUnsupportedValue(url, value: found)
        }
        return projectID
    }

    /// TOMLのエスケープなし基本文字列とリテラル文字列だけを受け付ける。
    /// エスケープ、複数行文字列、裸の値は、誤解釈せずfail-fastで拒否する。
    private static func quotedValue(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        if text.hasPrefix("\"\"\"") || text.hasPrefix("'''") { return nil }

        var value = ""
        var index = text.index(after: text.startIndex)
        var closed = false
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"", character == "\\" {
                return nil
            }
            if character == quote {
                closed = true
                index = text.index(after: index)
                break
            }
            value.append(character)
            index = text.index(after: index)
        }
        guard closed else { return nil }

        let trailing = text[index...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        return value
    }
}
