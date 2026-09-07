import AppKit
import DevSwitcherCore
import SwiftUI

/// ログ全体の再描画コストを避けるため`NSTextView`へ差分だけ反映する。
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    @Binding var isFollowing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFollowing: $isFollowing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: Spacing.s, height: Spacing.s)
            textView.font = NSFont.monospacedSystemFont(ofSize: Metrics.logFontSize, weight: .regular)
            textView.textContainer?.widthTracksTextView = true
            context.coordinator.textView = textView
        }

        context.coordinator.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.isFollowing = $isFollowing
        context.coordinator.apply(lines: lines, follow: isFollowing)
    }

    @MainActor
    final class Coordinator: NSObject {
        var isFollowing: Binding<Bool>
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        private var renderedIDs: [UInt64] = []
        private var renderedLengths: [Int] = []
        private var isProgrammaticScroll = false

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func apply(lines: [LogLine], follow: Bool) {
            guard let textView, let storage = textView.textStorage else { return }

            guard let first = lines.first else {
                if !renderedIDs.isEmpty {
                    storage.setAttributedString(NSAttributedString())
                    renderedIDs = []
                    renderedLengths = []
                }
                return
            }

            if let renderedFirst = renderedIDs.first, first.id < renderedFirst {
                // 別の起動でログ番号が振り直された。作り直す。
                rebuild(lines: lines, storage: storage)
                scrollIfNeeded(follow: follow)
                return
            }

            // バッファが捨てた行を、描画済みの先頭から同じ分だけ削る。
            if let renderedFirst = renderedIDs.first, first.id > renderedFirst {
                var dropCount = 0
                var dropLength = 0
                while dropCount < renderedIDs.count, renderedIDs[dropCount] < first.id {
                    dropLength += renderedLengths[dropCount]
                    dropCount += 1
                }
                if dropCount > 0 {
                    storage.deleteCharacters(
                        in: NSRange(location: 0, length: min(dropLength, storage.length))
                    )
                    renderedIDs.removeFirst(dropCount)
                    renderedLengths.removeFirst(dropCount)
                }
            }

            let appended: ArraySlice<LogLine>
            if let last = renderedIDs.last {
                appended = lines.drop { $0.id <= last }
            } else {
                appended = lines[...]
            }

            guard !appended.isEmpty else {
                scrollIfNeeded(follow: follow)
                return
            }

            for line in appended {
                let attributed = Coordinator.attributedLine(line)
                storage.append(attributed)
                renderedIDs.append(line.id)
                renderedLengths.append(attributed.length)
            }
            scrollIfNeeded(follow: follow)
        }

        private func rebuild(lines: [LogLine], storage: NSTextStorage) {
            let combined = NSMutableAttributedString()
            renderedIDs = []
            renderedLengths = []
            for line in lines {
                let attributed = Coordinator.attributedLine(line)
                combined.append(attributed)
                renderedIDs.append(line.id)
                renderedLengths.append(attributed.length)
            }
            storage.setAttributedString(combined)
        }

        private func scrollIfNeeded(follow: Bool) {
            guard follow, let textView else { return }
            isProgrammaticScroll = true
            textView.scrollToEndOfDocument(nil)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticScroll = false
            }
        }

        /// 過去ログを読んでいる最中に末尾へ引き戻さない。
        @objc func boundsDidChange(_ notification: Notification) {
            guard !isProgrammaticScroll,
                  let scrollView,
                  let documentView = scrollView.documentView
            else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= documentView.bounds.height - 8
            if isFollowing.wrappedValue != atBottom {
                isFollowing.wrappedValue = atBottom
            }
        }

        private static let timestampFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()

        private static func attributedLine(_ line: LogLine) -> NSAttributedString {
            let font = NSFont.monospacedSystemFont(ofSize: Metrics.logFontSize, weight: .regular)
            let result = NSMutableAttributedString()
            result.append(
                NSAttributedString(
                    string: timestampFormatter.string(from: line.timestamp) + "  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ]
                )
            )
            result.append(
                NSAttributedString(
                    string: line.text + "\n",
                    attributes: [
                        .font: font,
                        .foregroundColor: line.stream == .stderr
                            ? NSColor.systemRed
                            : NSColor.labelColor,
                    ]
                )
            )
            return result
        }
    }
}
