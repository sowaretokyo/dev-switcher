import Foundation

public enum ScriptPackageManager: String, CaseIterable, Sendable {
    case pnpm, npm, yarn, bun

    var lockfiles: [String] {
        switch self {
        case .pnpm: ["pnpm-lock.yaml"]
        case .npm: ["package-lock.json", "npm-shrinkwrap.json"]
        case .yarn: ["yarn.lock"]
        case .bun: ["bun.lock", "bun.lockb"]
        }
    }

    public func command(script: String, directory: URL) -> CommandSpec {
        CommandSpec(executable: rawValue, arguments: ["run", script], workingDirectory: directory)
    }
}

public struct DefinitionDiscoveryError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 検出はファイルの読み取りだけ。選択・編集・保存・起動はそれぞれ別の操作にする。
public enum DefinitionDiscovery {
    public struct Script: Equatable, Sendable, Identifiable {
        public let name: String
        public let body: String
        public var id: String { name }
    }

    public struct ManagerEvidence: Equatable, Sendable {
        public let manager: ScriptPackageManager
        public let files: [String]
    }

    public struct Compose: Equatable, Sendable {
        public let configuration: DockerComposeStackConfiguration
        public let projectName: String
        public let files: [String]
    }

    public struct Result: Equatable, Sendable {
        public let directory: URL
        public let scripts: [Script]
        public let managers: [ManagerEvidence]
        public let compose: Compose?
        /// ファイル単位の失敗は必ず表示し、成功した別の出典の候補と区別する。
        public let issues: [String]
        public let declaredPackageManager: String?
        // 選択からフォームへの反映までの変更を検知する。稼働状態や設定として保存しない。
        private let sources: [String: Data]
        private let managerDetectionFailed: Bool

        public var suggestedManager: ScriptPackageManager? {
            !managerDetectionFailed && managers.count == 1 ? managers[0].manager : nil
        }

        fileprivate init(directory: URL, scripts: [Script], managers: [ManagerEvidence],
                         compose: Compose?, issues: [String], declaredPackageManager: String?,
                         sources: [String: Data], managerDetectionFailed: Bool) {
            self.directory = directory
            self.scripts = scripts
            self.managers = managers
            self.compose = compose
            self.issues = issues
            self.declaredPackageManager = declaredPackageManager
            self.sources = sources
            self.managerDetectionFailed = managerDetectionFailed
        }
    }

    public static func scan(directory: URL) throws -> Result {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw DefinitionDiscoveryError("作業ディレクトリを絶対パスで指定してください。")
        }
        let directory = directory.standardizedFileURL
        // 親・子ディレクトリへ探索を広げず、直下の既知のファイルだけを読む。
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        var issues: [String] = []
        var scripts: [Script] = []
        var sources: [String: Data] = [:]
        var declaredPackageManager: String?
        if names.contains("package.json") {
            do {
                let data = try read(directory.appendingPathComponent("package.json"))
                let package = try JSONDecoder().decode(Package.self, from: data)
                scripts = try package.scripts.keys.sorted().map { name in
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !name.hasPrefix("-"), !name.contains("\0"),
                          let body = package.scripts[name],
                          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !body.contains("\0") else {
                        throw DefinitionDiscoveryError("scripts の名前またはコマンドが不正です（\(name)）。")
                    }
                    return Script(name: name, body: body)
                }
                declaredPackageManager = package.packageManager
                sources["package.json"] = data
            } catch {
                issues.append("package.json を取り込めません。\n\(error)")
            }
        }

        var managers: [ManagerEvidence] = []
        var managerDetectionFailed = false
        for manager in ScriptPackageManager.allCases {
            let files = manager.lockfiles.filter { names.contains($0) }
            guard !files.isEmpty else { continue }
            managers.append(ManagerEvidence(manager: manager, files: files))
            do {
                // lockfile の内容は読まず、実在する通常ファイルであることだけを確認する。
                for name in files { try checkFile(directory.appendingPathComponent(name)) }
            } catch {
                managerDetectionFailed = true
                issues.append("\(files.joined(separator: ", ")) を確認できません。\n\(error)")
            }
        }

        var compose: Compose?
        let bases = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        if bases.contains(where: names.contains) {
            do {
                let urls = try ComposeFileLocator.locate(files: nil, workingDirectory: directory)
                var contents: [String: Data] = [:]
                for url in urls { contents[url.lastPathComponent] = try read(url) }
                let projectName = try ComposeProjectNameReader.resolve(explicit: nil, files: urls).rawValue
                let files = urls.map(\.lastPathComponent)
                // 確認した名前とファイルを明示して、後から現れた override へ対象を変えない。
                compose = Compose(configuration: .init(projectName: projectName, files: files),
                                  projectName: projectName, files: files)
                sources.merge(contents) { _, new in new }
            } catch {
                issues.append("Compose を取り込めません。編集画面でファイルと projectName を指定できます。\n\(error)")
            }
        }
        return Result(directory: directory, scripts: scripts, managers: managers, compose: compose,
                      issues: issues, declaredPackageManager: declaredPackageManager, sources: sources,
                      managerDetectionFailed: managerDetectionFailed)
    }

    private struct Package: Decodable {
        let scripts: [String: String]
        let packageManager: String?
        enum CodingKeys: String, CodingKey { case scripts, packageManager }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // scripts は package.json では任意。存在する null・非文字列は欠落として扱わない。
            scripts = container.contains(.scripts)
                ? try container.decode([String: String].self, forKey: .scripts) : [:]
            packageManager = container.contains(.packageManager)
                ? try container.decode(String.self, forKey: .packageManager) : nil
        }
    }

    private static func checkFile(_ url: URL) throws {
        for path in [url, url.resolvingSymlinksInPath()] {
            let name = path.lastPathComponent
            guard name != ".env", name != ".envrc", !name.hasPrefix(".env.") else {
                throw DefinitionDiscoveryError("環境設定ファイルは読み取りません（\(url.lastPathComponent)）。")
            }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isReadable == true else {
            throw DefinitionDiscoveryError("読み取り可能な通常ファイルではありません（\(url.lastPathComponent)）。")
        }
    }

    private static func read(_ url: URL) throws -> Data {
        try checkFile(url)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else {
            throw DefinitionDiscoveryError("取り込み元は1 MiB以下のファイルにしてください（\(url.lastPathComponent)）。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else {
            throw DefinitionDiscoveryError("取り込み元が1 MiBを超えています（\(url.lastPathComponent)）。")
        }
        return data
    }
}
