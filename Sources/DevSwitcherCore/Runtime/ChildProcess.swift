import Darwin
import Foundation

public enum ExitStatus: Equatable, Sendable, CustomStringConvertible {
    case exited(code: Int32)
    case signaled(signal: Int32)
    /// 終了状態を取得できなかった。成功とは区別する。
    case unknown

    public var isSuccess: Bool {
        if case .exited(0) = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case let .exited(code): "終了コード \(code)"
        case let .signaled(signal): "シグナル \(signal) で終了"
        case .unknown: "終了状態を取得できませんでした"
        }
    }
}

/// 親終了後も残存グループを安全に停止できるよう、終了は `WNOWAIT` で観測し、
/// `release()` まで回収を遅らせる。ゾンビがPIDとPGIDの再利用を防ぐ。
/// 状態は専用のシリアルキュー上でのみ触る。`@unchecked Sendable` はそのための宣言。
public final class ChildProcess: @unchecked Sendable {
    public let pid: pid_t
    public let processGroupID: pid_t

    private let queue: DispatchQueue
    private var status: ExitStatus?
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<ExitStatus?, Never>] = [:]
    private var source: DispatchSourceProcess?

    public init(pid: pid_t, processGroupID: pid_t) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.queue = DispatchQueue(label: "jp.devswitcher.child.\(pid)")

        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.observeExit()
        }
        self.source = source
        source.resume()

        // ソース登録前に終了していた場合の取りこぼしを防ぐ。
        queue.async { [weak self] in
            self?.observeExit()
        }
    }

    deinit {
        source?.cancel()
        // 誰も停止操作をしなくなるので、ゾンビを残さないようここで回収する。
        if !isReleased, status != nil {
            var rawStatus: Int32 = 0
            _ = waitpid(pid, &rawStatus, WNOHANG)
        }
        // 待機中の継続を放置すると継続リークになるため、必ず解放する。
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: nil)
        }
    }

    /// 回収後のPGIDは再利用されうるため、呼び出し側は以後シグナルを送ってはならない。
    ///
    /// 回収できたときだけ true を返す。まだ終了していない場合や `waitpid` が失敗した場合は
    /// 所有権を保持したままにする（回収できていないのに解放済みとして扱わないため）。
    @discardableResult
    public func release() -> Bool {
        queue.sync {
            if isReleased { return true }
            guard status != nil else { return false }

            var rawStatus: Int32 = 0
            var result = waitpid(pid, &rawStatus, WNOHANG)
            while result == -1, errno == EINTR {
                result = waitpid(pid, &rawStatus, WNOHANG)
            }

            if result == pid || (result == -1 && errno == ECHILD) {
                // 回収できた、または既に他経路で回収されていた。
                isReleased = true
                return true
            }
            // result == 0（まだゾンビになっていない）や、その他の失敗。
            return false
        }
    }

    public var isProcessGroupOwned: Bool {
        queue.sync { !isReleased }
    }

    public var currentStatus: ExitStatus? {
        queue.sync { status }
    }

    public func waitForExit(timeout: Duration?) async -> ExitStatus? {
        await withCheckedContinuation { continuation in
            queue.async {
                if let status = self.status {
                    continuation.resume(returning: status)
                    return
                }
                let token = UUID()
                self.waiters[token] = continuation
                guard let timeout else { return }
                self.queue.asyncAfter(deadline: .now() + timeout.seconds) {
                    if let waiter = self.waiters.removeValue(forKey: token) {
                        waiter.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// PGIDの所有権を保つため、終了を観測してもここでは回収しない。
    private func observeExit() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard status == nil else { return }

        var info = siginfo_t()
        info.si_pid = 0
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
        let newStatus: ExitStatus
        if result == 0 {
            // まだ終了していない場合、si_pid は 0 のまま。
            guard info.si_pid != 0 else { return }
            switch info.si_code {
            case CLD_EXITED:
                newStatus = .exited(code: info.si_status)
            case CLD_KILLED, CLD_DUMPED:
                newStatus = .signaled(signal: info.si_status)
            default:
                // 停止・再開は終了ではない。
                return
            }
        } else if errno == ECHILD {
            // 別経路で回収済み。成功とは扱わず、所有権も主張しない。
            newStatus = .unknown
            isReleased = true
        } else {
            return
        }

        status = newStatus
        source?.cancel()
        source = nil

        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: newStatus)
        }
    }
}

extension Duration {
    var seconds: Double {
        let (secondsPart, attosecondsPart) = components
        return Double(secondsPart) + Double(attosecondsPart) / 1e18
    }
}
