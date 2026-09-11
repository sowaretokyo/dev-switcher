import Darwin
@testable import DevSwitcherCore
import Foundation
import Testing

/// テストが起動したプロセスグループを、fixture の寿命と一緒に必ず終了する。
///
/// 呼び出し側が `defer` を登録する前に setup が失敗しても、ローカル変数の破棄時に
/// 孫を含むグループへ SIGKILL を送り、直接の子であるリーダーを回収する。
final class TestProcessGroupCleanup: @unchecked Sendable {
    let processGroupID: pid_t

    private let pid: pid_t
    private let lock = NSLock()
    private var cleanupSucceeded = false

    init(_ process: SpawnedProcess) {
        pid = process.pid
        processGroupID = process.processGroupID
    }

    @discardableResult
    func cleanUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cleanupSucceeded { return true }

        let result = performCleanup()
        cleanupSucceeded = result
        return result
    }

    private func performCleanup() -> Bool {
        let signalResult = kill(-processGroupID, SIGKILL)
        let signalError = errno
        guard signalResult == 0 || signalError == ESRCH else { return false }

        let deadline = ContinuousClock.now + .seconds(2)
        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(pid, &rawStatus, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { break }
            if result == -1 && errno != EINTR { return false }
            if ContinuousClock.now >= deadline { return false }
            usleep(10_000)
        }

        while ContinuousClock.now < deadline {
            if ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false {
                return true
            }
            usleep(10_000)
        }
        return ProcessInspector.processGroupState(processGroupID).hasLiveMembers == false
    }

    deinit {
        if !cleanUp() {
            Issue.record("テスト用プロセスグループ \(processGroupID) を掃除できませんでした。")
        }
    }
}
