import Darwin
import Foundation

/// 停止判断に設定値を使わないよう、カーネルから得た情報だけを扱う。
public enum ProcessInspector {
    public static func identity(pid: pid_t, workingDirectory: URL) -> ProcessIdentity? {
        guard let startTime = startTimeMicroseconds(pid: pid),
              let path = executablePath(pid: pid)
        else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: startTime,
            executablePath: path,
            workingDirectory: workingDirectory
        )
    }

    /// `exec` は開始時刻を保ったまま実行ファイルを変えるため、パスを一致条件に含めない。
    /// PID再利用は開始時刻で検出し、パスと作業ディレクトリは表示と原因調査にだけ使う。
    public static func matchesRunningProcess(_ identity: ProcessIdentity) -> Bool {
        guard let startTime = startTimeMicroseconds(pid: identity.pid) else { return false }
        return startTime == identity.startTimeMicroseconds
    }

    public struct ProcessGroupMember: Equatable, Sendable {
        public let pid: pid_t
        public let isZombie: Bool
    }

    /// プロセスグループの観測結果。
    ///
    /// 取得の失敗を「プロセスなし」と混同すると、残っているプロセスを見落として
    /// 所有権を手放し、停止手段を失う。失敗は独立した状態として返す。
    public enum ProcessGroupState: Equatable, Sendable {
        /// 現在のメンバー。空配列はグループが空であることを意味する。
        case members([ProcessGroupMember])
        /// 取得できなかった。呼び出し側は「プロセスなし」と解釈してはいけない。
        case unavailable(errno: Int32)

        /// 動いている（ゾンビでない）プロセスが居るか。取得できなかった場合は nil。
        public var hasLiveMembers: Bool? {
            switch self {
            case let .members(members): members.contains { !$0.isZombie }
            case .unavailable: nil
            }
        }
    }

    /// `kill(-pgid, 0)` では「ゾンビだけが残っている」状態と
    /// 「動いているプロセスが居る」状態を区別できないため、カーネルから直接読む。
    public static func processGroupState(_ processGroupID: pid_t) -> ProcessGroupState {
        guard processGroupID > 0 else { return .unavailable(errno: EINVAL) }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, processGroupID]

        var size = 0
        errno = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), nil, &size, nil, 0)
        }
        guard sizeResult == 0 else { return .unavailable(errno: errno) }

        // 問い合わせの間にメンバーが増えることがあるので余裕を持たせ、
        // それでも足りなければ（ENOMEM）一度だけ広げて取り直す。
        for extraCapacity in [8, 64] {
            let capacity = size / MemoryLayout<kinfo_proc>.stride + extraCapacity
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var fetchedSize = capacity * MemoryLayout<kinfo_proc>.stride
            errno = 0
            let fetchResult = mib.withUnsafeMutableBufferPointer { buffer in
                sysctl(buffer.baseAddress, UInt32(buffer.count), &entries, &fetchedSize, nil, 0)
            }
            if fetchResult == 0 {
                let count = fetchedSize / MemoryLayout<kinfo_proc>.stride
                return .members(
                    (0..<count).map { index in
                        let process = entries[index].kp_proc
                        return ProcessGroupMember(
                            pid: process.p_pid,
                            isZombie: Int32(process.p_stat) == SZOMB
                        )
                    }
                )
            }
            guard errno == ENOMEM else { return .unavailable(errno: errno) }
        }
        return .unavailable(errno: ENOMEM)
    }

    /// 取得できなかった場合は nil。「プロセスなし」と解釈してはいけない。
    public static func processGroupMembers(_ processGroupID: pid_t) -> [ProcessGroupMember]? {
        guard case let .members(members) = processGroupState(processGroupID) else { return nil }
        return members
    }

    public static func startTimeMicroseconds(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let startTime = info.kp_proc.p_un.__p_starttime
        return UInt64(startTime.tv_sec) * 1_000_000 + UInt64(startTime.tv_usec)
    }

    public static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }
}
