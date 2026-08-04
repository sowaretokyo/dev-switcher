import Darwin
import Foundation

/// 停止判断に設定値を使わないよう、カーネルから得た情報だけを扱う。
public enum ProcessInspector {
    /// プロセス開始時刻の観測結果。
    ///
    /// `nil` だけでは「もう存在しない」と「権限不足などで読めない」を区別できない。
    /// 前者だけが古い記録を破棄できる根拠で、後者は再試行が必要なため型で分ける。
    public enum StartAbstimeObservation: Equatable, Sendable {
        case present(UInt64)
        case notPresent
        case unavailable(errno: Int32)

        public var value: UInt64? {
            guard case let .present(value) = self else { return nil }
            return value
        }
    }

    public static func identity(pid: pid_t, workingDirectory: URL) -> ProcessIdentity? {
        guard let startAbstime = startAbstime(pid: pid),
              let startTime = startTimeMicroseconds(pid: pid),
              let path = executablePath(pid: pid)
        else { return nil }
        return ProcessIdentity(
            pid: pid,
            startAbstime: startAbstime,
            startedAt: Date(timeIntervalSince1970: Double(startTime) / 1_000_000),
            executablePath: path,
            workingDirectory: workingDirectory
        )
    }

    /// `exec` は開始時刻を保ったまま実行ファイルを変えるため、パスを一致条件に含めない。
    /// PID再利用は boot 内の開始 abstime で検出する。wall-clock は時計の変更で前後するため使わない。
    /// パスと作業ディレクトリは表示と原因調査にだけ使う。
    public static func matchesRunningProcess(_ identity: ProcessIdentity) -> Bool {
        guard let startAbstime = startAbstime(pid: identity.pid) else { return false }
        return startAbstime == identity.startAbstime
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

    /// カレントディレクトリの実測。引き継ぎ候補が同じプロジェクト配下で動いているかの確認に使う。
    /// 取得できない場合は nil。「一致した」と解釈してはいけない。
    public static func workingDirectory(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, size)
        }
        guard result == size else { return nil }

        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return CStringDecoding.string(
                base.assumingMemoryBound(to: CChar.self),
                maximumLength: raw.count
            )
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// プロセスの開始時刻を boot 内の absolute time で返す。
    ///
    /// 同一性の判定にはこちらを使う。`startTimeMicroseconds` は wall-clock なので、
    /// NTP 補正や手動の時計変更で前後し、別プロセスが同じ値を取りうる。
    /// 読み取れないプロセス（別利用者など）は `.unavailable`、存在しない場合は
    /// `.notPresent` を返す。0などへ潰すと無関係なプロセスが一致してしまう。
    public static func startAbstimeObservation(pid: pid_t) -> StartAbstimeObservation {
        guard pid > 0 else { return .notPresent }
        var info = rusage_info_v0()
        var result: Int32 = -1
        errno = 0
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                result = proc_pid_rusage(pid, RUSAGE_INFO_V0, rebound)
            }
        }
        guard result == 0 else {
            let code = errno == 0 ? result : errno
            if code == ESRCH || code == ENOENT {
                return .notPresent
            }
            return .unavailable(errno: code)
        }
        return .present(info.ri_proc_start_abstime)
    }

    /// 表示など、存在しない理由を区別する必要がない補助用途だけで使う。
    /// 安全性やhint破棄の判断では `startAbstimeObservation(pid:)` を使うこと。
    public static func startAbstime(pid: pid_t) -> UInt64? {
        startAbstimeObservation(pid: pid).value
    }

    /// 起動セッションの識別子。
    ///
    /// mach absolute time は再起動でリセットされるため、これを添えないと
    /// 再起動をまたいだ別プロセスが同じ錨と一致しうる。
    /// 取得できない場合は wall-clock などへ退避せず nil を返し、呼び出し側を fail-closed にする。
    public static func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let identifier = CStringDecoding.string(buffer)
        return identifier.isEmpty ? nil : identifier
    }

    /// 実効ユーザーID。別利用者のプロセスへ終了操作を出さないための判定に使う。
    public static func userID(pid: pid_t) -> uid_t? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }
}
