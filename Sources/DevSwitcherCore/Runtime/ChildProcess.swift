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
    private var pollSource: DispatchSourceTimer?

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

        // 非常に短命な子は、初回確認の直後かつプロセス終了通知の監視が
        // 確立する前に終了することがある。通知だけに依存せず、同じ直列
        // キューで終了状態を再確認して取りこぼしを防ぐ。
        let pollSource = DispatchSource.makeTimerSource(queue: queue)
        pollSource.schedule(
            deadline: .now(),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        pollSource.setEventHandler { [weak self] in
            self?.observeExit()
        }
        self.pollSource = pollSource

        source.resume()
        pollSource.resume()

        // ソース登録前に終了していた場合の取りこぼしを防ぐ。
        queue.async { [weak self] in
            self?.observeExit()
        }
    }

    deinit {
        source?.cancel()
        pollSource?.cancel()
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

    /// 終了状態と PGID 所有権を1回で読む。
    ///
    /// この2つを別々に読むと、間で所有権を失った PGID へシグナルを送れてしまう。
    /// 読むたびにカーネルへ問い合わせて最新化する。通知（`DispatchSourceProcess`）と
    /// 250ms のポーリングだけに頼ると、負荷時に配送が遅れて
    /// 「もう終了しているのに動作中」と読め、短命プロセスをヘルスチェックが通す。
    public struct Snapshot: Equatable, Sendable {
        public let status: ExitStatus?
        /// リーダーを未回収で保持しているか。false なら PGID は再利用されうる。
        public let ownsProcessGroup: Bool

        public var isRunning: Bool { status == nil }
    }

    public var snapshot: Snapshot {
        queue.sync {
            observeExit()
            refreshOwnershipAfterObservedExit()
            return Snapshot(status: status, ownsProcessGroup: !isReleased)
        }
    }

    public var currentStatus: ExitStatus? { snapshot.status }

    public func waitForExit(timeout: Duration?) async -> ExitStatus? {
        await withCheckedContinuation { continuation in
            queue.async {
                // 待機登録の前に一度観測する。登録してから通知を待つと、
                // 既に終了しているプロセスを猶予いっぱい待つことになる。
                self.observeExit()
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
        pollSource?.cancel()
        pollSource = nil

        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: newStatus)
        }
    }

    /// `WNOWAIT` で終了を観測した後に別経路が子を回収することがある。
    /// 終了状態を一度キャッシュしただけで所有権まで固定すると、既に再利用可能なPGIDへ
    /// シグナルを送りうるため、snapshotごとにカーネル上の回収状態を再確認する。
    private func refreshOwnershipAfterObservedExit() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard status != nil, !isReleased else { return }

        var info = siginfo_t()
        info.si_pid = 0
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
        if result == -1, errno == ECHILD {
            isReleased = true
        }
    }
}

extension Duration {
    var seconds: Double {
        let (secondsPart, attosecondsPart) = components
        return Double(secondsPart) + Double(attosecondsPart) / 1e18
    }
}
