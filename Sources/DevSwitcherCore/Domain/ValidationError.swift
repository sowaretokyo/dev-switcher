import Foundation

/// 必須値の欠落を補完せず、入力元まで特定できるエラーとして返す。
public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case projectNameEmpty
    case duplicateProjectName(String)
    case duplicateProjectID(UUID)
    case projectDirectoryEmpty
    case projectDirectoryNotAbsolute(String)
    case projectDirectoryMissing(URL)
    case projectDirectoryNotADirectory(URL)
    case noServices
    case serviceNameEmpty(serviceIndex: Int)
    case duplicateServiceName(String)
    case duplicateServiceID(UUID)
    case executableEmpty(service: String)
    case emptyArgument(service: String, argumentIndex: Int)
    case workingDirectoryMissing(service: String, url: URL)
    case portNotANumber(service: String, value: String)
    case portOutOfRange(service: String, port: Int)
    case duplicatePortInService(service: String, port: Int)
    case duplicatePortAcrossServices(port: Int, services: [String])
    case missingPrimaryPort(service: String)
    case multiplePrimaryPorts(service: String)
    case portLabelEmpty(service: String, port: Int)
    case invalidOpenURL(service: String, value: String)

    public var description: String {
        switch self {
        case .projectNameEmpty:
            "プロジェクト名が空です。"
        case let .duplicateProjectName(name):
            "プロジェクト名「\(name)」は既に登録されています。"
        case let .duplicateProjectID(id):
            "プロジェクト ID が重複しています（\(id.uuidString)）。"
        case .projectDirectoryEmpty:
            "プロジェクトのディレクトリが指定されていません。"
        case let .projectDirectoryNotAbsolute(path):
            "プロジェクトのディレクトリは絶対パスで指定してください（\(path)）。"
        case let .projectDirectoryMissing(url):
            "プロジェクトのディレクトリが存在しません（\(url.path)）。"
        case let .projectDirectoryNotADirectory(url):
            "プロジェクトのパスがディレクトリではありません（\(url.path)）。"
        case .noServices:
            "サービスが1つも登録されていません。"
        case let .serviceNameEmpty(index):
            "\(index + 1) 番目のサービス名が空です。"
        case let .duplicateServiceName(name):
            "サービス名「\(name)」がプロジェクト内で重複しています。"
        case let .duplicateServiceID(id):
            "サービス ID が重複しています（\(id.uuidString)）。"
        case let .executableEmpty(service):
            "サービス「\(service)」の実行ファイルが空です。"
        case let .emptyArgument(service, index):
            "サービス「\(service)」の \(index + 1) 番目の引数が空文字です。"
        case let .workingDirectoryMissing(service, url):
            "サービス「\(service)」の作業ディレクトリが存在しません（\(url.path)）。"
        case let .portNotANumber(service, value):
            "サービス「\(service)」のポート「\(value)」は数値として解釈できません。"
        case let .portOutOfRange(service, port):
            "サービス「\(service)」のポート \(port) が範囲外です（\(PortSpec.validRange.lowerBound)〜\(PortSpec.validRange.upperBound)）。"
        case let .duplicatePortInService(service, port):
            "サービス「\(service)」でポート \(port) が重複しています。"
        case let .duplicatePortAcrossServices(port, services):
            "起動対象のサービス間でポート \(port) が重複しています（\(services.joined(separator: " / "))）。"
        case let .missingPrimaryPort(service):
            "サービス「\(service)」に代表ポートが指定されていません。"
        case let .multiplePrimaryPorts(service):
            "サービス「\(service)」に代表ポートが複数指定されています。1つだけ指定してください。"
        case let .portLabelEmpty(service, port):
            "サービス「\(service)」のポート \(port) のラベルが空文字です。ラベルを入力するか未設定にしてください。"
        case let .invalidOpenURL(service, value):
            "サービス「\(service)」の開く URL「\(value)」は http / https の URL として解釈できません。"
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
