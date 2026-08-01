import DevSwitcherCore
import Foundation
import Observation

/// 長時間稼働でメモリを使い続けないよう上限を設け、欠落を隠さないよう破棄件数も残す。
@MainActor
@Observable
final class LogBuffer {
    static let capacity = 20_000

    private(set) var lines: [LogLine] = []
    private(set) var droppedCount = 0

    func append(_ batch: [LogLine]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > LogBuffer.capacity {
            let overflow = lines.count - LogBuffer.capacity
            lines.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    func clear() {
        lines.removeAll()
        droppedCount = 0
    }

    var stderrCount: Int {
        lines.reduce(into: 0) { count, line in
            if line.stream == .stderr { count += 1 }
        }
    }
}
