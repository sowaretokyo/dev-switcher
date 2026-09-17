import AppKit
@testable import DevSwitcherApp
import DevSwitcherCore
import SwiftUI
import Testing

@Suite("ログ表示のプロセス切り替え")
@MainActor
struct LogTextViewTests {
    private let sessionID = UUID()

    @Test("空状態が描画されない再起動でも、新しい世代のログだけを表示する", arguments: [0..<0, 0..<2, 0..<4, 0..<6, 4..<8])
    func replacesLogsWhenSessionChanges(ids: Range<Int>) {
        let textView = NSTextView()
        let coordinator = LogTextView.Coordinator(isFollowing: .constant(false))
        coordinator.textView = textView
        let serviceID = UUID()
        let buffer = LogBuffer()
        buffer.append(lines("old", ids: 0..<4))
        coordinator.apply(
            serviceID: serviceID, sessionID: buffer.sessionID, lines: buffer.lines, follow: false
        )

        // SwiftUIが空の状態を描画する前に、新しいログが届く順序を再現する。
        buffer.clear()
        buffer.append(lines("new", ids: ids))
        coordinator.apply(
            serviceID: serviceID, sessionID: buffer.sessionID, lines: buffer.lines, follow: false
        )
        #expect(messages(in: textView) == buffer.lines.map(\.text))

        buffer.append(lines("new", ids: ids.upperBound..<(ids.upperBound + 2)))
        coordinator.apply(
            serviceID: serviceID, sessionID: buffer.sessionID, lines: buffer.lines, follow: false
        )
        #expect(messages(in: textView) == buffer.lines.map(\.text))
    }

    @Test("行番号が重なっても切り替え先のログだけを表示する", arguments: [0..<2, 0..<4, 0..<6, 2..<4])
    func replacesLogsWhenServiceChanges(ids: Range<Int>) {
        let textView = NSTextView()
        let coordinator = LogTextView.Coordinator(isFollowing: .constant(false))
        coordinator.textView = textView
        let serverID = UUID()
        let supabaseID = UUID()
        let serverLines = lines("Server", ids: 0..<4)
        let supabaseLines = lines("Supabase", ids: ids)

        coordinator.apply(serviceID: serverID, sessionID: sessionID, lines: serverLines, follow: false)
        #expect(messages(in: textView) == serverLines.map(\.text))

        coordinator.apply(serviceID: supabaseID, sessionID: sessionID, lines: supabaseLines, follow: false)
        #expect(messages(in: textView) == supabaseLines.map(\.text))

        coordinator.apply(serviceID: serverID, sessionID: sessionID, lines: serverLines, follow: false)
        #expect(messages(in: textView) == serverLines.map(\.text))
    }

    @Test("空ログへの切り替えで前の表示を消し、その後のログも表示する")
    func switchesToEmptyLogs() {
        let textView = NSTextView()
        let coordinator = LogTextView.Coordinator(isFollowing: .constant(false))
        coordinator.textView = textView
        let supabaseID = UUID()
        coordinator.apply(serviceID: UUID(), sessionID: sessionID, lines: lines("Server", ids: 0..<4), follow: false)

        coordinator.apply(serviceID: supabaseID, sessionID: sessionID, lines: [], follow: false)
        #expect(textView.string.isEmpty)

        let supabaseLines = lines("Supabase", ids: 0..<2)
        coordinator.apply(serviceID: supabaseID, sessionID: sessionID, lines: supabaseLines, follow: false)
        #expect(messages(in: textView) == supabaseLines.map(\.text))

        coordinator.apply(serviceID: supabaseID, sessionID: sessionID, lines: [], follow: false)
        #expect(textView.string.isEmpty)
    }

    @Test("切り替え後もログを重複なく追記し、破棄された先頭行を取り除く")
    func updatesLogsAfterSwitching() {
        let textView = NSTextView()
        let coordinator = LogTextView.Coordinator(isFollowing: .constant(false))
        coordinator.textView = textView
        let supabaseID = UUID()
        coordinator.apply(serviceID: UUID(), sessionID: sessionID, lines: lines("Server", ids: 0..<4), follow: false)

        for ids in [0..<2, 0..<3, 0..<3, 1..<4] {
            let supabaseLines = lines("Supabase", ids: ids)
            coordinator.apply(serviceID: supabaseID, sessionID: sessionID, lines: supabaseLines, follow: false)
            #expect(messages(in: textView) == supabaseLines.map(\.text))
        }
    }

    private func lines(_ service: String, ids: Range<Int>) -> [LogLine] {
        ids.map {
            LogLine(
                id: UInt64($0),
                timestamp: Date(timeIntervalSince1970: 1),
                stream: .stdout,
                text: "\(service) \($0)"
            )
        }
    }

    private func messages(in textView: NSTextView) -> [String] {
        textView.string.split(separator: "\n").map {
            String($0.dropFirst("HH:mm:ss.SSS  ".count))
        }
    }
}
