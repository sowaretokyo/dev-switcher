import Darwin
import Foundation

/// 設定ポートを稼働中と誤認しないよう、実測値を`PortSpec`と別の型で持つ。
public struct ObservedPort: Equatable, Hashable, Sendable {
    public let port: Int
    public let pid: pid_t
    public let address: String

    public init(port: Int, pid: pid_t, address: String) {
        self.port = port
        self.pid = pid
        self.address = address
    }
}

public enum PortInspectorError: Error, Sendable, CustomStringConvertible {
    case executableMissing(path: String)
    case failed(standardError: String)
    case abnormalTermination(status: ExitStatus, standardError: String)
    case unparsableOutput(line: String)
    case timedOut(seconds: Double)

    public var description: String {
        switch self {
        case let .executableMissing(path):
            L10n.text("\(path) が見つかりません。ポートの実測ができません。")
        case let .failed(standardError):
            L10n.text("lsof の実行に失敗しました。\n\(standardError)")
        case let .abnormalTermination(status, standardError):
            L10n.text("""
                lsof が異常終了しました（\(status.description)）。\
                出力が空でも「ポートなし」とは判断できません。
                """)
                + (standardError.isEmpty ? "" : "\n\(standardError)")
        case let .unparsableOutput(line):
            L10n.text("lsof の出力を解析できませんでした（\(line)）。")
        case let .timedOut(seconds):
            L10n.text("lsof が \(Int(seconds)) 秒以内に終了しませんでした。")
        }
    }
}

/// ポートの実測結果。
///
/// 「実測して0件だった」と「実測できなかった」を同じ空配列で表さない。
/// 混同すると、観測に失敗しただけのサービスを「ポートを持たないサービス」として
/// ポート照合なしで引き継いでしまう。
public enum ObservedPortRecord: Codable, Equatable, Sendable {
    case observed([Int])
    case unavailable

    public var observed: [Int]? {
        guard case let .observed(ports) = self else { return nil }
        return ports
    }

    public var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }
}

/// ポートを握っているプロセスの実測結果。所有区分の判定はここでは行わない。
/// 「Dev Switcher が起動したものか」は起動側の記録と突き合わせて初めて決まるため。
public struct ObservedPortHolder: Equatable, Sendable {
    public let port: Int
    public let pid: pid_t
    public let processGroupID: pid_t?
    public let command: String?
    public let loginName: String?

    public init(
        port: Int,
        pid: pid_t,
        processGroupID: pid_t?,
        command: String?,
        loginName: String?
    ) {
        self.port = port
        self.pid = pid
        self.processGroupID = processGroupID
        self.command = command
        self.loginName = loginName
    }
}

/// 設定値からの推測は行わない。解析に失敗した場合は「ポートなし」ではなくエラーを返す。
public enum PortInspector {
    public static let executable = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// lsof の終了状態を検査する。
    ///
    /// lsof は「該当なし」でも終了コード 1 を返すため、1 は正常系として扱う。
    /// ただしシグナル終了やそれ以外の終了コードは異常であり、
    /// そのとき出力が空でも「ポートが空いている」とは判断できない。
    /// 2段階ゲートの根拠なので、ここは黙って通さない。
    static func checkTermination(_ captured: CapturedOutput) throws {
        switch captured.status {
        case let .exited(code) where code == 0 || code == 1:
            return
        case .exited, .signaled, .unknown:
            throw PortInspectorError.abnormalTermination(
                status: captured.status,
                standardError: captured.standardErrorText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public static func listeningPorts(
        processGroupID: pid_t,
        timeout: Duration = .seconds(10)
    ) async throws -> [ObservedPort] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PortInspectorError.executableMissing(path: executable.path)
        }

        let arguments = [
            "-nP",           // 名前解決をしない（速度と表記の安定のため）
            "-F", "pgn",     // フィールド形式で pid / pgid / 名前を出す
            "-a",
            "-g", String(processGroupID),
            "-i", "TCP",
            "-sTCP:LISTEN",
        ]

        let captured: CapturedOutput
        do {
            captured = try await CommandOutput.capture(
                executable: executable,
                arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                workingDirectory: URL(fileURLWithPath: "/"),
                timeout: timeout
            )
        } catch let error as CommandOutputError {
            if case let .timedOut(_, seconds) = error {
                throw PortInspectorError.timedOut(seconds: seconds)
            }
            throw PortInspectorError.failed(standardError: error.description)
        }

        try checkTermination(captured)

        let standardOutput = captured.standardOutputText
        let standardError = captured.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 正常終了のうえで出力が空なら「listen なし」と判断できる。
        if standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !standardError.isEmpty {
                throw PortInspectorError.failed(standardError: standardError)
            }
            return []
        }

        return try parse(standardOutput)
    }

    /// 指定したポート番号を listen しているプロセスを調べる。
    ///
    /// ゲート検証で使う。解析できなかった出力を「空いている」と解釈すると、
    /// 別プロジェクトのサービスが残っているのに起動を許してしまう。失敗はエラーとして返す。
    public static func holders(
        ofPorts ports: [Int],
        timeout: Duration = .seconds(10)
    ) async throws -> [ObservedPortHolder] {
        let targets = Array(Set(ports)).sorted()
        guard !targets.isEmpty else { return [] }

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PortInspectorError.executableMissing(path: executable.path)
        }

        // 利用者入力を連結せず、検証済みの整数だけを固定引数へ渡す。
        let arguments = [
            "-nP",
            "-F", "pcLgn",
            "-i", "TCP:" + targets.map(String.init).joined(separator: ","),
            "-sTCP:LISTEN",
        ]

        let captured: CapturedOutput
        do {
            captured = try await CommandOutput.capture(
                executable: executable,
                arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                workingDirectory: URL(fileURLWithPath: "/"),
                timeout: timeout
            )
        } catch let error as CommandOutputError {
            if case let .timedOut(_, seconds) = error {
                throw PortInspectorError.timedOut(seconds: seconds)
            }
            throw PortInspectorError.failed(standardError: error.description)
        }

        try checkTermination(captured)

        let standardOutput = captured.standardOutputText
        let standardError = captured.standardErrorText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !standardError.isEmpty {
                throw PortInspectorError.failed(standardError: standardError)
            }
            return []
        }

        // 問い合わせたポート以外（同じプロセスが持つ別の listen）は結果へ混ぜない。
        return try parseHolders(standardOutput).filter { targets.contains($0.port) }
    }

    static func parseHolders(_ output: String) throws -> [ObservedPortHolder] {
        var holders: [ObservedPortHolder] = []
        var pid: pid_t?
        var processGroupID: pid_t?
        var command: String?
        var loginName: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                guard let parsed = pid_t(value) else {
                    throw PortInspectorError.unparsableOutput(line: line)
                }
                // 新しいプロセスの開始。前のプロセスの属性を引き継がせない。
                pid = parsed
                processGroupID = nil
                command = nil
                loginName = nil
            case "g":
                guard let parsed = pid_t(value) else {
                    throw PortInspectorError.unparsableOutput(line: line)
                }
                processGroupID = parsed
            case "c":
                command = value
            case "L":
                loginName = value
            case "n":
                guard let pid else {
                    throw PortInspectorError.unparsableOutput(line: line)
                }
                let (_, port) = try parseAddress(value, line: line)
                holders.append(
                    ObservedPortHolder(
                        port: port,
                        pid: pid,
                        processGroupID: processGroupID,
                        command: command,
                        loginName: loginName
                    )
                )
            default:
                continue
            }
        }

        return holders
    }

    static func parse(_ output: String) throws -> [ObservedPort] {
        var ports: [ObservedPort] = []
        var currentPID: pid_t?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                guard let pid = pid_t(value) else {
                    throw PortInspectorError.unparsableOutput(line: line)
                }
                currentPID = pid
            case "n":
                guard let pid = currentPID else {
                    throw PortInspectorError.unparsableOutput(line: line)
                }
                let (address, port) = try parseAddress(value, line: line)
                ports.append(ObservedPort(port: port, pid: pid, address: address))
            default:
                continue
            }
        }

        return ports
    }

    private static func parseAddress(_ value: String, line: String) throws -> (String, Int) {
        guard let separatorIndex = value.lastIndex(of: ":") else {
            throw PortInspectorError.unparsableOutput(line: line)
        }
        let address = String(value[value.startIndex..<separatorIndex])
        let portText = String(value[value.index(after: separatorIndex)...])
        guard let port = Int(portText), PortSpec.validRange.contains(port) else {
            throw PortInspectorError.unparsableOutput(line: line)
        }
        return (address, port)
    }
}
