import Darwin
import Foundation

/// プロセスを一意に指す錨。
///
/// PID は再利用されるため単独では使えない。boot 内の absolute time
/// （`rusage_info_v0.ri_proc_start_abstime`）を組にして、同じ PID の別プロセスと区別する。
/// wall-clock ではないので、NTP 補正や手動の時計変更で前後しない。
///
/// mach absolute time は再起動でリセットされるため、この型だけでは再起動をまたげない。
/// 起動セッションと組にして使うこと（`ProcessGroupEvidence`）。
public struct ProcessAnchor: Codable, Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startAbstime: UInt64

    public init(pid: pid_t, startAbstime: UInt64) {
        self.pid = pid
        self.startAbstime = startAbstime
    }

    /// 実測して錨を作る。読み取れないプロセスでは nil。
    public static func measure(pid: pid_t) -> ProcessAnchor? {
        guard case let .present(startAbstime) = ProcessInspector.startAbstimeObservation(pid: pid)
        else { return nil }
        return ProcessAnchor(pid: pid, startAbstime: startAbstime)
    }

    public var description: String {
        "PID \(pid)"
    }
}

/// プロセスグループを同定するための証拠。
///
/// 「記録した時点で確かにこのグループに居たプロセス」を具体的に保持する。
/// 時刻の範囲や作業ディレクトリのような、他のプロセスも満たしうる条件は根拠にしない。
public struct ProcessGroupEvidence: Codable, Equatable, Sendable {
    public let bootSessionID: String
    public let anchors: [ProcessAnchor]

    public init(bootSessionID: String, anchors: [ProcessAnchor]) {
        self.bootSessionID = bootSessionID
        self.anchors = anchors
    }

    public var isEmpty: Bool { anchors.isEmpty }
}

/// PID は再利用されるため、PID だけでは同じプロセスだと判断しない。
/// シグナル送出前に、記録した錨と現在値を照合する。
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: pid_t
    /// 同一性の判定に使う。boot 内の absolute time。
    public let startAbstime: UInt64
    /// 表示と原因調査に使う。wall-clock なので同一性の判定には使わない。
    public let startedAt: Date
    public let executablePath: String
    public let workingDirectory: URL

    public init(
        pid: pid_t,
        startAbstime: UInt64,
        startedAt: Date,
        executablePath: String,
        workingDirectory: URL
    ) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.startedAt = startedAt
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
    }

    public var anchor: ProcessAnchor {
        ProcessAnchor(pid: pid, startAbstime: startAbstime)
    }
}
