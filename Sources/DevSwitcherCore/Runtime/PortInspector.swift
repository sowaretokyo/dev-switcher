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
    case unparsableOutput(line: String)
    case timedOut(seconds: Double)

    public var description: String {
        switch self {
        case let .executableMissing(path):
            "\(path) が見つかりません。ポートの実測ができません。"
        case let .failed(standardError):
            "lsof の実行に失敗しました。\n\(standardError)"
        case let .unparsableOutput(line):
            "lsof の出力を解析できませんでした（\(line)）。"
        case let .timedOut(seconds):
            "lsof が \(Int(seconds)) 秒以内に終了しませんでした。"
        }
    }
}

/// 設定値からの推測は行わない。解析に失敗した場合は「ポートなし」ではなくエラーを返す。
public enum PortInspector {
    public static let executable = URL(fileURLWithPath: "/usr/sbin/lsof")

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

        let standardOutput = captured.standardOutputText
        let standardError = captured.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)

        // lsof は該当プロセスがない場合も終了コード 1 を返す。
        // 標準出力が空でも標準エラーが空なら「listen なし」と判断できる。
        if standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !standardError.isEmpty {
                throw PortInspectorError.failed(standardError: standardError)
            }
            return []
        }

        return try parse(standardOutput)
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
