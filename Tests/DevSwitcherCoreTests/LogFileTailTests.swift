@testable import DevSwitcherCore
import Foundation
import Synchronization
import Testing

@Suite("ログファイルの追尾")
struct LogFileTailTests {
    @Test("大量の未読ログも分割して通知し、末尾まで読み切る", arguments: [false, true])
    func batchesUnreadLogsWhenFinishing(cancel: Bool) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeLogFiles(in: directory)
        let recorder = BatchRecorder()
        let tail = try makeTail(files: files, recorder: recorder)
        defer { tail.cancel() }

        // 空の状態で追尾を開始し、次の定期読み取りより先に終了時の読み切りを行う。
        tail.drain()
        let output = (0..<600).map { paddedLine("out-\($0)") }
        let errors = (0..<600).map { paddedLine("err-\($0)") }
        try Data((output.joined(separator: "\n") + "\nlast-out").utf8)
            .write(to: files.standardOutput)
        try Data((errors.joined(separator: "\n") + "\nlast-err").utf8)
            .write(to: files.standardError)

        if cancel {
            tail.cancel()
        } else {
            tail.drain()
        }

        let received = recorder.received
        let lines = received.flatMap { $0 }
        #expect(received.count > 1)
        #expect(received.allSatisfy { batch in
            batch.reduce(0) { $0 + $1.text.utf8.count } <= 256 * 1024
        })
        #expect(lines.filter { $0.stream == .stdout }.map(\.text) == output + ["last-out"])
        #expect(lines.filter { $0.stream == .stderr }.map(\.text) == errors + ["last-err"])
        #expect(lines.map(\.id) == (0..<lines.count).map { UInt64($0) })
    }

    @Test("読み切り後は追記を受け取り、追尾停止後は再度読み切っても通知しない")
    func doesNotReadAfterCancellation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeLogFiles(in: directory)
        let recorder = BatchRecorder()
        let tail = try makeTail(files: files, recorder: recorder)
        defer { tail.cancel() }
        let writer = try FileHandle(forWritingTo: files.standardOutput)
        defer { try? writer.close() }

        try writer.write(contentsOf: Data("before".utf8))
        tail.drain()
        tail.drain()
        #expect(recorder.received.flatMap { $0 }.map(\.text) == ["before"])

        try writer.write(contentsOf: Data("after\npartial".utf8))
        tail.cancel()
        #expect(recorder.received.flatMap { $0 }.map(\.text) == ["before", "after", "partial"])

        try writer.write(contentsOf: Data("must-not-appear\n".utf8))
        tail.cancel()
        tail.drain()
        #expect(recorder.received.flatMap { $0 }.map(\.text) == ["before", "after", "partial"])
    }

    private func makeLogFiles(in directory: URL) throws -> ServiceLogFiles {
        let files = ServiceLogFiles(directory: directory, serviceID: UUID())
        try Data().write(to: files.standardOutput)
        try Data().write(to: files.standardError)
        return files
    }

    private func makeTail(
        files: ServiceLogFiles,
        recorder: BatchRecorder
    ) throws -> LogFileTail {
        try LogFileTail(
            files: [
                (files.standardOutput, .stdout),
                (files.standardError, .stderr),
            ],
            label: UUID().uuidString,
            interval: .seconds(60),
            onBatch: { recorder.append($0) },
            onFailure: { Issue.record("ログの読み取りに失敗: \($0)") }
        )
    }

    /// 改行込みで1024 bytesとし、256 KiBの読み取り境界をまたぐ未読量を作る。
    private func paddedLine(_ prefix: String) -> String {
        prefix + String(repeating: "x", count: 1023 - prefix.utf8.count)
    }

    private final class BatchRecorder: Sendable {
        private let batches = Mutex<[[LogLine]]>([])

        var received: [[LogLine]] { batches.withLock { $0 } }

        func append(_ batch: [LogLine]) {
            batches.withLock { $0.append(batch) }
        }
    }
}
