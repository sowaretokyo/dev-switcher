import Darwin
@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 起動・停止・切替の進捗をどこに出すかの検証。
///
/// 単純な起動・停止は画面を遮らずインラインで出し、停止を伴う切替だけシートを出す。
/// 多重操作を止めているのはシートではなく `AppState` の排他トークンなので、
/// シートが無い状態でも別操作が始まらないことをあわせて確かめる。
@Suite("起動・停止の進捗表示")
@MainActor
struct AppStateOperationTests {
    /// 引き継ぎ経由で起動済みを作る。実プロセスを起動しないので、
    /// プロセス観測の権限に依存せず「動いているプロジェクトがある」状態を作れる。
    private func adoptRunningService(
        state: AppState,
        fixture: SyntheticFixture
    ) async throws {
        try await adoptRunningService(state: state, fixture: fixture, capturingSinkWith: nil)
    }

    /// 引き継ぎの実行中に、その操作へ紐づいた進捗の受け口を取り出せるようにした版。
    /// `gate` を渡した場合は、引き継ぎ処理を止めた状態で受け口を取り、その後再開する。
    @discardableResult
    private func adoptRunningService(
        state: AppState,
        fixture: SyntheticFixture,
        capturingSinkWith gate: ArmedGate?
    ) async throws -> SwitchCoordinator.ProgressSink? {
        state.loadProjects()
        // 環境を ready にしておく。起動を止めているのが環境ではないことを確かめるため。
        await state.loadEnvironment()
        await state.reviewHandoffCandidates()
        let presentation = try #require(state.handoffPresentation)

        var sink: SwitchCoordinator.ProgressSink?
        if let gate {
            await gate.arm()
            state.performHandoffAction(.adopt, presentationID: presentation.id)
            #expect(await gate.waitUntilReached())
            sink = state.progressSinkForCurrentActivity()
            await gate.release()
        } else {
            state.performHandoffAction(.adopt, presentationID: presentation.id)
        }
        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(state.canStartServices)
        #expect(state.phase(of: fixture.project) == .running)
        return sink
    }

    @Test("単純な停止ではシートを出さず、対象プロジェクトにインライン進捗を出す")
    func stopShowsInlineProgressWithoutSheet() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        try ProjectStore(directory: directory).save([fixture.project])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        try await adoptRunningService(state: state, fixture: fixture)

        state.stopProject(fixture.project)
        // 受け付けた直後に、対象と操作種別が分かること。
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation?.projectID == fixture.project.id)
        #expect(state.inlineOperation?.kind == .stopping)
        #expect(state.phase(of: fixture.project) == .stopping)

        await state.waitForPendingOperation()

        #expect(state.operationError == nil)
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation == nil)
        #expect(state.phase(of: fixture.project) == .stopped)
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
    }

    @Test("起動に失敗してもシートを出さず、インライン進捗を解除する")
    func failedStartClearsInlineProgressWithoutSheet() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let hintStore = ControllableHintStore(directory: directory)

        let state = makeAppState(directory: directory, hintStore: hintStore)
        await state.bootstrap()
        #expect(state.canStart)

        // 事前保存で失敗させる。プロセスは1つも起動しないので、
        // 進捗表示の解除だけを決定的に確かめられる。
        hintStore.failAllSaves()
        state.startOrSwitch(to: project)
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation?.projectID == project.id)
        #expect(state.inlineOperation?.kind == .starting)
        #expect(state.phase(of: project) == .starting)

        await state.waitForPendingOperation()

        #expect(state.operationError != nil)
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation == nil)
        #expect(state.state(of: project.services[0].id).processID == nil)
    }

    @Test("別プロジェクトへの切替ではシートを出し、インライン進捗を使わない")
    func switchPresentsSheetInsteadOfInlineProgress() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSyntheticFixture(directory: directory)
        let target = makeWorkerProject(name: "Penta", directory: directory)
        try ProjectStore(directory: directory).save([fixture.project, target])
        let hintStore = ControllableHintStore(directory: directory)
        try hintStore.save([fixture.hint], legacy: [])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector,
            hintStore: hintStore
        )
        try await adoptRunningService(state: state, fixture: fixture)

        // 事前保存で失敗させ、実プロセスを起動せずに切替の入口だけを確かめる。
        hintStore.failAllSaves()
        state.startOrSwitch(to: target)

        let presentation = try #require(state.switchPresentation)
        #expect(presentation.sourceName == fixture.project.name)
        #expect(presentation.targetName == target.name)
        #expect(state.inlineOperation == nil)

        await state.waitForPendingOperation()

        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation == nil)
        // 事前保存に失敗した切替では、切替元を停止しない。
        #expect(state.phase(of: fixture.project) == .running)
        #expect(fixture.signals.sent.isEmpty)
    }

    @Test("停止の実行中は、別プロジェクトの起動も設定変更も受け付けない")
    func inFlightOperationRejectsOtherOperations() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 停止フェーズのポート実測で止める。準備段階も同じ経路を通るので、
        // 武装できる門を使って停止の途中だけを止める。
        let gate = ArmedGate()
        let fixture = makeSyntheticFixture(
            directory: directory,
            portProbe: { _ in
                await gate.passOrWait()
                return []
            }
        )
        let other = makeWorkerProject(name: "Penta", directory: directory)
        try ProjectStore(directory: directory).save([fixture.project, other])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )
        try await adoptRunningService(state: state, fixture: fixture)

        await gate.arm()
        state.stopProject(fixture.project)
        #expect(await gate.waitUntilReached())

        // インライン進捗は操作した1件にだけ出る。
        #expect(state.inlineOperation?.projectID == fixture.project.id)
        #expect(state.inlineOperation?.projectID != other.id)
        #expect(state.switchPresentation == nil)

        // シートで遮っていなくても、API 境界で拒否する。
        #expect(state.canStart == false)
        #expect(state.canStop == false)
        #expect(state.canChangeConfiguration == false)

        let importData = try JSONEncoder().encode(ProjectsDocument(projects: [other]))
        #expect(throws: AppError.self) { try state.previewProjectImport(importData, path: "input.json") }
        #expect(throws: AppError.self) { try state.importProjects([other]) }
        state.presentProjectImport()
        #expect(!state.isProjectImportPresented)

        state.startOrSwitch(to: other)
        #expect(state.inlineOperation?.projectID == fixture.project.id)
        #expect(state.switchPresentation == nil)
        #expect(state.state(of: other.services[0].id).processID == nil)

        state.stopProject(fixture.project)
        #expect(state.inlineOperation?.kind == .stopping)

        state.setEnabledNow(false, for: other.services[0], in: other)
        #expect(state.project(other.id)?.isEnabledNow(other.services[0].id) == true)

        await gate.release()
        await state.waitForPendingOperation()

        #expect(state.inlineOperation == nil)
        #expect(state.phase(of: fixture.project) == .stopped)
        // 拒否した2度目の停止でシグナルが二重送出されていない。
        #expect(fixture.signals.sent.map(\.signal) == [SIGTERM])
    }

    @Test("終わった操作の進捗が遅れて届いても、次の操作の表示と中止導線を書き換えない")
    func staleProgressDoesNotLeakIntoTheNextOperation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ポート実測で処理を止める。準備段階と検証対象が同じ経路を通るので武装できる門を使う。
        let gate = ArmedGate()
        let fixture = makeSyntheticFixture(
            directory: directory,
            portProbe: { _ in
                await gate.passOrWait()
                return []
            }
        )
        let target = makeWorkerProject(name: "Penta", directory: directory)
        try ProjectStore(directory: directory).save([fixture.project, target])
        try RuntimeHintStore(directory: directory).save([fixture.hint])

        let state = makeAppState(
            directory: directory,
            registry: fixture.registry,
            handoffInspector: fixture.inspector
        )

        // 操作A（引き継ぎ）の実行中に、その操作の進捗の受け口を取っておく。
        let staleSink = try #require(
            await adoptRunningService(state: state, fixture: fixture, capturingSinkWith: gate)
        )

        // 操作B（切替）を、起動フェーズへ入る前の事前保存で止める。
        await gate.arm()
        state.startOrSwitch(to: target)
        #expect(await gate.waitUntilReached())
        defer {
            // 実プロセスを残さない。停止シグナルは記録用に差し替えてあるため実際には届かない。
            if let group = state.state(of: target.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        let switching = try #require(state.switchPresentation)
        #expect(switching.state == .idle)
        #expect(switching.canCancel)

        // 操作Aの `.completed` がいま届いても、Bの進捗・中止導線・インライン表示は変わらない。
        staleSink(.completed)
        let leaked = await waitForCondition(timeout: .milliseconds(400)) {
            state.switchPresentation?.state != .idle
                || state.switchPresentation?.canCancel != true
                || state.inlineOperation != nil
        }
        #expect(leaked == false)

        // 「イベントが1件も処理されていなかっただけ」との取り違えを避けるため、
        // 現在の操作の進捗は同じ経路で反映されることを確かめる。
        let currentSink = try #require(state.progressSinkForCurrentActivity())
        let current = SwitchState.stopping(service: "Worker", index: 1, total: 1)
        currentSink(current)
        #expect(await waitForCondition { state.switchPresentation?.state == current })
        #expect(state.switchPresentation?.canCancel == true)
        #expect(state.phase(of: fixture.project) == .stopping)

        await gate.release()
        await state.waitForPendingOperation()
    }

    @Test("実プロセスの起動でもシートを出さず、完了後にインライン進捗を解除する")
    func realProcessStartShowsInlineProgressWithoutSheet() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])

        let state = makeAppState(directory: directory)
        await state.bootstrap()

        state.startOrSwitch(to: project)
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation?.projectID == project.id)
        #expect(state.inlineOperation?.kind == .starting)

        await state.waitForPendingOperation()
        defer {
            if let group = state.state(of: project.services[0].id).processGroupID {
                kill(-group, SIGKILL)
            }
        }

        #expect(state.operationError == nil)
        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation == nil)
        #expect(state.phase(of: project) == .running)

        // 停止しても最後までシートは出ない。
        state.stopProject(project)
        #expect(state.switchPresentation == nil)
        await state.waitForPendingOperation()

        #expect(state.switchPresentation == nil)
        #expect(state.inlineOperation == nil)
        #expect(state.phase(of: project) == .stopped)
    }

    @Test("起動確認後の終了はhealthyの画面反映前でも通知する")
    func confirmedExitIsReportedBeforeHealthyUIState() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(directory: directory)
        state.loadProjects()
        let service = try #require(state.project(project.id)?.services.first)
        let events = state.serviceEventSinkForTesting()

        events(
            service.id,
            .exited(
                status: .exited(code: 2),
                requestedByUser: false,
                startupConfirmed: false
            )
        )
        #expect(await waitForCondition {
            state.state(of: service.id).lastMessage == "終了コード 2"
        })
        #expect(state.runtimeIncident == nil)

        events(service.id, .logSessionStarted)
        events(
            service.id,
            .exited(
                status: .exited(code: 7),
                requestedByUser: false,
                startupConfirmed: true
            )
        )
        #expect(await waitForCondition {
            state.runtimeIncident?.serviceID == service.id
        })
        #expect(state.runtimeIncident?.status == "終了コード 7")
    }

    @Test("確定済みの対象外を遅れた終了通知で停止中へ戻さない")
    func delayedRequestedExitPreservesExcludedPhase() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = makeWorkerProject(directory: directory)
        project.services[0].enabledByDefault = false
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let service = project.services[0]
        try #require(state.state(of: service.id).phase == .excluded)

        // 補償停止後の状態反映が先に済み、終了通知だけが後から届いた順序を再現する。
        // 次のrefreshPhasesを待たず、通知の適用直後にも状態を壊していないことを見る。
        state.apply(
            .exited(status: .signaled(signal: SIGTERM), requestedByUser: true, startupConfirmed: true),
            to: service.id
        )
        #expect(state.state(of: service.id).phase == .excluded)
        #expect(state.state(of: service.id).processID == nil)
        #expect(state.state(of: service.id).lastMessage == ExitStatus.signaled(signal: SIGTERM).description)
        #expect(state.runtimeIncident == nil)
    }
}
