import AppKit
import Foundation

/// 終了要求の受け口。
///
/// 手掛かりの書き出しは非同期なので、終了を待たせてから結果を返す。
/// 書き出せなかった場合は終了を取り消す。残っているプロセスの手掛かりを失ったまま
/// 終了すると、次回起動時に検出も停止もできなくなる。
///
/// `AppState` を optional にしない。結び付く前の要求を素通りさせる隙間を作らないため。
/// `NSApplication` から切り離してあるのは、この判断をテストで確かめられるようにするため。
@MainActor
final class TerminationCoordinator {
    private let appState: AppState
    private var isFlushing = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// - Parameter reply: 書き出しが終わったあとに呼ぶ。終了してよいかを渡す。
    /// - Returns: AppKit へ返す判断。必ず待たせる。
    func shouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        // 書き出し中に届いた2度目の要求も待たせる。ここで即時終了を返すと、
        // 書き出しの完了を待たずにアプリが落ちる。
        guard !isFlushing else { return .terminateLater }

        isFlushing = true
        Task { @MainActor in
            let canTerminate = await appState.flushRuntimeHintsBeforeTermination()
            self.isFlushing = false
            reply(canTerminate)
        }
        return .terminateLater
    }
}
