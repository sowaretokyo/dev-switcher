@testable import DevSwitcherApp
import DevSwitcherCore
import Foundation
import Testing

@Suite("ログのセッションと出力先")
@MainActor
struct LogBufferTests {
    @Test("stdoutとstderrの本文・出力先を保持し、stderrの行数を数える")
    func preservesStreamsAndCountsStandardError() {
        let buffer = LogBuffer()

        let batch = [
            line(id: 1, stream: .stdout, text: "ready"),
            line(id: 2, stream: .stderr, text: "$ next dev"),
            line(id: 3, stream: .stderr, text: "Starting containers..."),
        ]
        buffer.append(batch)

        #expect(buffer.lines == batch)
        #expect(buffer.stderrCount == 2)
    }

    @Test("新しい起動セッションでは過去ログと行数を消す")
    func clearsPreviousSession() {
        let buffer = LogBuffer()
        let previousSessionID = buffer.sessionID
        buffer.append([
            line(id: 1, stream: .stderr, text: "old error"),
        ])
        #expect(buffer.sessionID == previousSessionID)

        buffer.clear()

        #expect(buffer.lines.isEmpty)
        #expect(buffer.stderrCount == 0)
        #expect(buffer.droppedCount == 0)
        #expect(buffer.sessionID != previousSessionID)
    }

    private func line(id: UInt64, stream: LogLine.Stream, text: String) -> LogLine {
        LogLine(id: id, timestamp: Date(timeIntervalSince1970: 1), stream: stream, text: text)
    }
}
