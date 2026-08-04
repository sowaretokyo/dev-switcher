import AppKit
import Darwin
import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 終了要求の受け口の検証。
/// AppKit の終了シーケンス（⌘Q → shouldTerminate → reply）と同じ順序で駆動する。
@Suite("終了要求の扱い")
@MainActor
struct TerminationCoordinatorTests {
    private func makeState(
        directory: URL,
        hintStore: (any RuntimeHintPersisting)? = nil
    ) -> AppState {
        AppState(
            registry: RuntimeRegistry(
                portPollInterval: .seconds(60),
                logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                environmentLoader: { fixedShellEnvironment }
            ),
            store: ProjectStore(directory: directory),
            hintStore: hintStore ?? RuntimeHintStore(directory: directory)
        )
    }

    @Test("書き出しを待たせてから、終了してよいと返す")
    func repliesTrueAfterFlush() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try RuntimeHintStore(directory: directory).save([])
        let state = makeState(directory: directory)
        let coordinator = TerminationCoordinator(appState: state)

        let replies = ReplyRecorder()
        let decision = coordinator.shouldTerminate { replies.record($0) }
        // 書き出しが終わるまで終了させない。
        #expect(decision == .terminateLater)

        #expect(await waitForCondition { replies.values.count == 1 })
        #expect(replies.values == [true])
    }

    @Test("書き出せなければ、終了を取り消す")
    func repliesFalseWhenFlushFails() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hintStore = ControllableHintStore(directory: directory)
        try hintStore.save([], legacy: [])
        let state = makeState(directory: directory, hintStore: hintStore)
        #expect(state.ensureHintsLoaded())
        // 読み込みは成功させ、書き込みだけ失敗させる。
        hintStore.failAllSaves()

        let coordinator = TerminationCoordinator(appState: state)
        let replies = ReplyRecorder()
        #expect(coordinator.shouldTerminate { replies.record($0) } == .terminateLater)

        #expect(await waitForCondition { replies.values.count == 1 })
        // 手掛かりを失ったまま終了させない。
        #expect(replies.values == [false])
    }

    @Test("書き出し中の2度目の要求も待たせる")
    func secondRequestDuringFlushAlsoWaits() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        // bootstrap を止めて、書き出しが進行中の状態を作る。
        let gate = TestGate()
        let state = AppState(
            registry: RuntimeRegistry(
                portPollInterval: .seconds(60),
                logDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                environmentLoader: {
                    await gate.markReached()
                    await gate.waitForRelease()
                    return fixedShellEnvironment
                }
            ),
            store: ProjectStore(directory: directory),
            hintStore: RuntimeHintStore(directory: directory)
        )

        let bootstrapTask = Task { await state.bootstrap() }
        #expect(await gate.waitUntilReached())

        let coordinator = TerminationCoordinator(appState: state)
        let replies = ReplyRecorder()
        #expect(coordinator.shouldTerminate { replies.record($0) } == .terminateLater)
        // 書き出しの完了を待たずに落ちないよう、2度目も待たせる。
        #expect(coordinator.shouldTerminate { replies.record($0) } == .terminateLater)
        #expect(replies.values.isEmpty)

        await gate.release()
        #expect(await waitForCondition { replies.values.count == 1 })
        await bootstrapTask.value
    }

    @Test("画面が出る前の終了要求でも、書き出しを待たせる")
    func repliesLaterBeforeAnyViewAppears() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try RuntimeHintStore(directory: directory).save([])
        // bootstrap も画面表示も済ませずに終了要求を出す。
        // 以前は AppState が結び付く前だと即時終了になり、直列化を素通りしていた。
        let state = makeState(directory: directory)
        let coordinator = TerminationCoordinator(appState: state)

        let replies = ReplyRecorder()
        #expect(coordinator.shouldTerminate { replies.record($0) } == .terminateLater)
        #expect(await waitForCondition { replies.values.count == 1 })
        #expect(replies.values == [true])
    }
}

/// 終了可否の通知を記録する。
@MainActor
final class ReplyRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}
