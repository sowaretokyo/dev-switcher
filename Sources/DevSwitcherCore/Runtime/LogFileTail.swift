import Darwin
import Foundation

public struct ServiceLogFiles: Equatable, Sendable {
    public let standardOutput: URL
    public let standardError: URL

    public init(directory: URL, serviceID: UUID) {
        standardOutput = directory
            .appendingPathComponent("\(serviceID.uuidString)-stdout.log", isDirectory: false)
        standardError = directory
            .appendingPathComponent("\(serviceID.uuidString)-stderr.log", isDirectory: false)
    }
}

enum LogFileReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(path: String, code: Int32)
    case notRegularFile(path: String)

    var description: String {
        switch self {
        case let .unreadable(path, code):
            "ログファイルを読み取れません（\(path) / errno \(code): \(CStringDecoding.errorMessage(code))）。"
        case let .notRegularFile(path):
            "ログの保存先が通常のファイルではありません（\(path)）。"
        }
    }
}

/// 改行のない出力でメモリを無制限に使わないよう、一定長でも行を確定する。
struct LineAssembler {
    static let maxLineLength = 8192

    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var lines: [[UInt8]] = []
        var lineStart = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == UInt8(ascii: "\n") {
                lines.append(Array(buffer[lineStart..<index]))
                index += 1
                lineStart = index
            } else if index - lineStart >= LineAssembler.maxLineLength {
                lines.append(Array(buffer[lineStart...index]))
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        buffer = Array(buffer[lineStart...])
        return lines
    }

    mutating func flush() -> [UInt8]? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer = []
        return remainder
    }
}

/// pipeはアプリ終了後の書き込みでサービスをSIGPIPE終了させるため採用せず、ファイルを追尾する。
/// stdoutとstderrを分ける以上、書き込み時刻が残らず厳密な相対順序は復元できない。
/// 1ファイルへの統合はストリームの区別を失い、中継プロセスは別の寿命管理が必要になるため、
/// 短周期の交互読みで順序のずれを抑えるところまでを許容範囲とする。
final class LogFileTail: @unchecked Sendable {
    typealias BatchHandler = @Sendable ([LogLine]) -> Void

    private struct Source {
        let fileDescriptor: Int32
        let url: URL
        let stream: LogLine.Stream
        var assembler = LineAssembler()
        var failed = false
    }

    private let queue: DispatchQueue
    private let onBatch: BatchHandler
    private let onFailure: @Sendable (LogFileReadError) -> Void
    private var sources: [Source] = []
    private var timer: DispatchSourceTimer?
    private var nextID: UInt64 = 0
    private var isCancelled = false

    init(
        files: [(url: URL, stream: LogLine.Stream)],
        label: String,
        interval: Duration = .milliseconds(40),
        onBatch: @escaping BatchHandler,
        onFailure: @escaping @Sendable (LogFileReadError) -> Void
    ) throws {
        self.queue = DispatchQueue(label: "jp.devswitcher.log.\(label)")
        self.onBatch = onBatch
        self.onFailure = onFailure

        var opened: [Source] = []
        do {
            for file in files {
                let descriptor = open(file.url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    throw LogFileReadError.unreadable(path: file.url.path, code: errno)
                }
                var info = stat()
                guard fstat(descriptor, &info) == 0 else {
                    let code = errno
                    close(descriptor)
                    throw LogFileReadError.unreadable(path: file.url.path, code: code)
                }
                guard info.st_mode & S_IFMT == S_IFREG else {
                    close(descriptor)
                    throw LogFileReadError.notRegularFile(path: file.url.path)
                }
                opened.append(Source(fileDescriptor: descriptor, url: file.url, stream: file.stream))
            }
        } catch {
            for source in opened { close(source.fileDescriptor) }
            throw error
        }
        sources = opened

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval.seconds)
        timer.setEventHandler { [weak self] in
            self?.readAvailable(flushRemainder: false)
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        for source in sources {
            close(source.fileDescriptor)
        }
    }

    func drain() {
        queue.sync {
            readAvailable(flushRemainder: true)
        }
    }

    func cancel() {
        queue.sync {
            guard !isCancelled else { return }
            isCancelled = true
            readAvailable(flushRemainder: true)
            timer?.cancel()
            timer = nil
        }
    }

    private func readAvailable(flushRemainder: Bool) {
        guard !isCancelled || flushRemainder else { return }

        var lines: [LogLine] = []
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        var pending = Set(sources.indices.filter { !sources[$0].failed })
        var bytesRead = 0

        // 片方の大量出力でもう片方が後ろへ回らないよう、小さく交互に読む。
        // 引き継ぎ時の大きな保存済みログも、1回の通知で全量をメモリへ積まない。
        while !pending.isEmpty, flushRemainder || bytesRead < 256 * 1024 {
            for index in sources.indices where pending.contains(index) {
                let descriptor = sources[index].fileDescriptor
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    pending.remove(index)
                    if code != EAGAIN {
                        sources[index].failed = true
                        onFailure(.unreadable(path: sources[index].url.path, code: code))
                    }
                    continue
                }
                guard count > 0 else {
                    pending.remove(index)
                    continue
                }
                bytesRead += count
                let chunk = Array(buffer[0..<count])
                for line in sources[index].assembler.append(chunk) {
                    lines.append(makeLine(bytes: line, stream: sources[index].stream))
                }
                if count < buffer.count {
                    pending.remove(index)
                }
            }
        }

        if flushRemainder {
            for index in sources.indices {
                if let remainder = sources[index].assembler.flush() {
                    lines.append(makeLine(bytes: remainder, stream: sources[index].stream))
                }
            }
        }

        guard !lines.isEmpty else { return }
        onBatch(lines)
    }

    private func makeLine(bytes: [UInt8], stream: LogLine.Stream) -> LogLine {
        var slice = bytes[...]
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        let line = LogLine(
            id: nextID,
            timestamp: Date(),
            stream: stream,
            text: String(decoding: slice, as: UTF8.self)
        )
        nextID += 1
        return line
    }
}
