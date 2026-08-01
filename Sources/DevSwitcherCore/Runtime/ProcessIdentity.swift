import Darwin
import Foundation

/// PID は再利用されるため、PID だけでは同じプロセスだと判断しない。
/// シグナル送出前に、記録した開始時刻と現在値を照合する。
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: pid_t
    /// `kinfo_proc` から得た開始時刻（1970-01-01 からのマイクロ秒）。
    /// Date へ丸めると比較が甘くなるため、整数のまま保持する。
    public let startTimeMicroseconds: UInt64
    public let executablePath: String
    public let workingDirectory: URL

    public init(
        pid: pid_t,
        startTimeMicroseconds: UInt64,
        executablePath: String,
        workingDirectory: URL
    ) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(startTimeMicroseconds) / 1_000_000)
    }
}
