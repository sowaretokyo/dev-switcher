@testable import DevSwitcherApp
import DevSwitcherCore
import Foundation
import Testing

@Suite("ログのセッションと未読stderr")
@MainActor
struct LogBufferTests {
    @Test("stderrだけを未読として数え、開いたら既読にする")
    func tracksUnreadStandardError() {
        let buffer = LogBuffer()

        buffer.append([
            line(id: 1, stream: .stdout, text: "ready"),
            line(id: 2, stream: .stderr, text: "compile error"),
            line(id: 3, stream: .stderr, text: "stack trace"),
        ])

        #expect(buffer.stderrCount == 2)
        #expect(buffer.unreadStderrCount == 2)

        buffer.markStderrAsRead()

        #expect(buffer.stderrCount == 2)
        #expect(buffer.unreadStderrCount == 0)
    }

    @Test("新しい起動セッションでは過去ログと未読数を消す")
    func clearsPreviousSession() {
        let buffer = LogBuffer()
        buffer.append([
            line(id: 1, stream: .stderr, text: "old error"),
        ])

        buffer.clear()

        #expect(buffer.lines.isEmpty)
        #expect(buffer.stderrCount == 0)
        #expect(buffer.unreadStderrCount == 0)
        #expect(buffer.droppedCount == 0)
    }

    private func line(id: UInt64, stream: LogLine.Stream, text: String) -> LogLine {
        LogLine(id: id, timestamp: Date(timeIntervalSince1970: 1), stream: stream, text: text)
    }
}
