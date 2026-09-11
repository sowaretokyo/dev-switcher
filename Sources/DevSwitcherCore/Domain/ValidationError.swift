import Foundation

/// 必須値の欠落を補完せず、入力元まで特定できるエラーとして返す。
public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case projectNameEmpty
    case duplicateProjectName(String)
    case duplicateProjectID(UUID)
    case noWorkingDirectories
    case workingDirectoryNameEmpty(directoryIndex: Int)
    case duplicateWorkingDirectoryName(String)
    case duplicateWorkingDirectoryID(UUID)
    case workingDirectoryPathEmpty(name: String)
    case workingDirectoryPathNotAbsolute(name: String, path: String)
    case duplicateWorkingDirectoryPath(URL)
    case workingDirectoryHasNoServices(name: String)
    case workingDirectoryUnknownService(name: String, id: UUID)
    case serviceInMultipleWorkingDirectories(service: String)
    case serviceWithoutWorkingDirectory(service: String)
    case serviceWorkingDirectoryMismatch(service: String, expected: URL, actual: URL)
    case namedWorkingDirectoryMissing(name: String, url: URL)
    case namedWorkingDirectoryNotADirectory(name: String, url: URL)
    case noServices
    case serviceNameEmpty(serviceIndex: Int)
    case duplicateServiceName(String)
    case duplicateServiceID(UUID)
    case duplicateServiceIDAcrossProjects(UUID)
    case executableEmpty(service: String)
    case emptyArgument(service: String, argumentIndex: Int)
    case workingDirectoryMissing(service: String, url: URL)
    case portNotANumber(service: String, value: String)
    case portOutOfRange(service: String, port: Int)
    case duplicatePortInService(service: String, port: Int)
    case missingPrimaryPort(service: String)
    case multiplePrimaryPorts(service: String)
    case portLabelEmpty(service: String, port: Int)
    case invalidOpenURL(service: String, value: String)
    case stopOrderMissingService(service: String)
    case stopOrderUnknownService(id: UUID)
    case stopOrderDuplicate(service: String)
    case enabledNowUnknownService(id: UUID)
    case stopExecutableEmpty(service: String)
    case stopEmptyArgument(service: String, argumentIndex: Int)
    case supabaseCustomStopUnsupported(service: String)
    case supabaseCommandUnsupported(service: String)
    case supabaseStartSubcommandMissing(service: String)
    case supabaseWorkdirValueMissing(service: String)
    case supabaseForbiddenStopOption(service: String, option: String)
    case multipleSupabaseServices(services: [String])
    case supabaseProjectIDUnresolved(service: String, reason: String)
    case duplicateSupabaseProjectID(projectID: String, otherProject: String)

    public var description: String {
        switch self {
        case .projectNameEmpty:
            "開発環境名が空です。"
        case let .duplicateProjectName(name):
            "開発環境名「\(name)」は既に登録されています。"
        case let .duplicateProjectID(id):
            "開発環境 ID が重複しています（\(id.uuidString)）。"
        case .noWorkingDirectories:
            "作業ディレクトリが1件も登録されていません。"
        case let .workingDirectoryNameEmpty(index):
            "\(index + 1) 番目の作業ディレクトリ名が空です。"
        case let .duplicateWorkingDirectoryName(name):
            "作業ディレクトリ名「\(name)」が開発環境内で重複しています。"
        case let .duplicateWorkingDirectoryID(id):
            "作業ディレクトリ ID が重複しています（\(id.uuidString)）。"
        case let .workingDirectoryPathEmpty(name):
            "作業ディレクトリ「\(name)」の場所が指定されていません。"
        case let .workingDirectoryPathNotAbsolute(name, path):
            "作業ディレクトリ「\(name)」は絶対パスで指定してください（\(path)）。"
        case let .duplicateWorkingDirectoryPath(url):
            "同じ作業ディレクトリが複数登録されています（\(url.path)）。"
        case let .workingDirectoryHasNoServices(name):
            "作業ディレクトリ「\(name)」にプロセスが1件も登録されていません。"
        case let .workingDirectoryUnknownService(name, id):
            "作業ディレクトリ「\(name)」に存在しないプロセス ID が含まれています（\(id.uuidString)）。"
        case let .serviceInMultipleWorkingDirectories(service):
            "プロセス「\(service)」が複数の作業ディレクトリに登録されています。"
        case let .serviceWithoutWorkingDirectory(service):
            "プロセス「\(service)」に作業ディレクトリが割り当てられていません。"
        case let .serviceWorkingDirectoryMismatch(service, expected, actual):
            "プロセス「\(service)」の実行場所が所属ディレクトリと一致しません（所属: \(expected.path)、実行場所: \(actual.path)）。"
        case let .namedWorkingDirectoryMissing(name, url):
            "作業ディレクトリ「\(name)」が存在しません（\(url.path)）。"
        case let .namedWorkingDirectoryNotADirectory(name, url):
            "作業ディレクトリ「\(name)」のパスがディレクトリではありません（\(url.path)）。"
        case .noServices:
            "プロセスが1つも登録されていません。"
        case let .serviceNameEmpty(index):
            "\(index + 1) 番目のプロセス名が空です。"
        case let .duplicateServiceName(name):
            "プロセス名「\(name)」が開発環境内で重複しています。"
        case let .duplicateServiceID(id):
            "プロセス ID が重複しています（\(id.uuidString)）。"
        case let .duplicateServiceIDAcrossProjects(id):
            "プロセス ID が別の開発環境と重複しています（\(id.uuidString)）。"
        case let .executableEmpty(service):
            "プロセス「\(service)」の実行ファイルが空です。"
        case let .emptyArgument(service, index):
            "プロセス「\(service)」の \(index + 1) 番目の引数が空文字です。"
        case let .workingDirectoryMissing(service, url):
            "プロセス「\(service)」の作業ディレクトリが存在しません（\(url.path)）。"
        case let .portNotANumber(service, value):
            "プロセス「\(service)」のポート「\(value)」は数値として解釈できません。"
        case let .portOutOfRange(service, port):
            "プロセス「\(service)」のポート \(port) が範囲外です（\(PortSpec.validRange.lowerBound)〜\(PortSpec.validRange.upperBound)）。"
        case let .duplicatePortInService(service, port):
            "プロセス「\(service)」でポート \(port) が重複しています。"
        case let .missingPrimaryPort(service):
            "プロセス「\(service)」に代表ポートが指定されていません。"
        case let .multiplePrimaryPorts(service):
            "プロセス「\(service)」に代表ポートが複数指定されています。1つだけ指定してください。"
        case let .portLabelEmpty(service, port):
            "プロセス「\(service)」のポート \(port) のラベルが空文字です。ラベルを入力するか未設定にしてください。"
        case let .invalidOpenURL(service, value):
            "プロセス「\(service)」の開く URL「\(value)」は http / https の URL として解釈できません。"
        case let .stopOrderMissingService(service):
            "終了順にプロセス「\(service)」が含まれていません。終了順を指定する場合は全プロセスを並べてください。"
        case let .stopOrderUnknownService(id):
            "終了順に、この開発環境に存在しないプロセス ID が含まれています（\(id.uuidString)）。"
        case let .stopOrderDuplicate(service):
            "終了順でプロセス「\(service)」が重複しています。"
        case let .enabledNowUnknownService(id):
            "起動対象の指定に、この開発環境に存在しないプロセス ID が含まれています（\(id.uuidString)）。"
        case let .stopExecutableEmpty(service):
            "プロセス「\(service)」の終了コマンドの実行ファイルが空です。"
        case let .stopEmptyArgument(service, index):
            "プロセス「\(service)」の終了コマンドの \(index + 1) 番目の引数が空文字です。"
        case let .supabaseCustomStopUnsupported(service):
            "Supabase「\(service)」の終了コマンドは個別に指定できません。起動コマンドから導出した `supabase stop` を使用します。"
        case let .supabaseCommandUnsupported(service):
            "Supabase「\(service)」の起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
        case let .supabaseStartSubcommandMissing(service):
            "Supabase「\(service)」の起動コマンドに `start` サブコマンドがありません。"
        case let .supabaseWorkdirValueMissing(service):
            "Supabase「\(service)」の `--workdir` にディレクトリが指定されていません。"
        case let .supabaseForbiddenStopOption(service, option):
            "Supabase「\(service)」の起動コマンドに `\(option)` は指定できません。複数プロジェクトやバックアップを巻き込むため、Dev Switcherでは実行しません。"
        case let .multipleSupabaseServices(services):
            "1つの開発環境に登録できる Supabase は1件までです（\(services.joined(separator: " / "))）。起動対象から外していても登録できません。"
        case let .supabaseProjectIDUnresolved(service, reason):
            "Supabase「\(service)」の `project_id` を取得できません。\n\(reason)"
        case let .duplicateSupabaseProjectID(projectID, otherProject):
            "Supabase の `project_id`「\(projectID)」は開発環境「\(otherProject)」で既に使用されています。同じスタックを複数の開発環境から扱う構成は対象外です。"
        }
    }
}

public struct ValidationFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let errors: [ValidationError]

    public init(errors: [ValidationError]) {
        self.errors = errors
    }

    public var description: String {
        errors.map(\.description).joined(separator: "\n")
    }
}
