import Foundation
import Testing
@testable import DevSwitcherCore

/// Phase A のリファクタ前に、管理対象スタック（現行ではSupabase）の利用者向け文言と
/// 状態判定の意味を固定する特性テスト。期待値は現行ソースから写した文字列リテラルで、
/// 同じ実装で計算しない。文言を変える変更は、このテストが落ちることで検出される。
@Suite("管理対象スタックの特性（文言・状態判定）")
struct ManagedStackCharacterizationTests {
    // MARK: - 部品

    private func registration(
        _ projectName: String,
        _ serviceName: String = "Supabase"
    ) -> ManagedStackConfirmationTarget.Registration {
        ManagedStackConfirmationTarget.Registration(
            environmentName: projectName,
            stackName: serviceName,
            directory: URL(fileURLWithPath: "/tmp/\(projectName.lowercased())")
        )
    }

    private func plan(
        serviceID: UUID = UUID(),
        target: ManagedStackConfirmationTarget,
        stopTargets: [ManagedStackConfirmationTarget] = [],
        snapshot: ManagedStackSnapshot = ManagedStackSnapshot(type: .supabase, observations: [])
    ) -> ManagedStackConfirmationPlan {
        // 起動先の行は serviceID を stackID に持ち、停止行は stackID を持たない。
        ManagedStackConfirmationPlan(
            environmentName: "Demo",
            entries: [
                ManagedStackConfirmationTarget(
                    stackID: serviceID,
                    identity: target.identity,
                    state: target.state,
                    action: target.action,
                    registration: target.registration
                ),
            ] + stopTargets,
            snapshot: snapshot,
            fingerprints: [serviceID: .supabase(makeSupabaseFingerprint())]
        )
    }

    private func target(
        _ rawValue: String,
        _ state: ManagedStackState,
        _ action: ManagedStackConfirmationTarget.Action,
        registration: ManagedStackConfirmationTarget.Registration?
    ) throws -> ManagedStackConfirmationTarget {
        ManagedStackConfirmationTarget(
            stackID: nil,
            identity: try makeSupabaseIdentity(rawValue),
            state: state,
            action: action,
            registration: registration
        )
    }

    private func supabaseService(
        arguments: [String] = ["start"],
        executable: String = "supabase",
        stop: CommandSpec? = nil,
        directory: URL
    ) -> LaunchUnit {
        var service = makeSupabaseService(
            workingDirectory: directory,
            executable: executable,
            arguments: arguments
        )
        service.stop = stop
        return service
    }

    // MARK: - SwitchFailure.Reason

    @Test("managedStackConfirmationRequired は複数の停止行を、対象→停止対象の順に登録有無つきで並べる")
    func confirmationRequiredDetail() throws {
        let plan = plan(
            target: try target("demo", .running, .adopt, registration: registration("Demo")),
            // 並びは観測順ではなく渡した順のまま出る（sampleはlegacyより先に渡している）。
            stopTargets: [
                try target("sample", .degraded, .stop, registration: registration("Sample")),
                try target("legacy", .running, .stop, registration: nil),
            ]
        )
        let reason = SwitchFailure.Reason.managedStackConfirmationRequired(plan: plan)

        #expect(reason.title == "Supabaseの確認")
        #expect(
            reason.detail == """
                サービス「Supabase」の起動前に、既存のSupabaseスタックの扱いを確認してください。
                demo: 稼働中 → 引き継ぐ（Demo / Supabase）
                sample: 一部だけ稼働 → 停止する（Sample / Supabase）
                legacy: 稼働中 → 停止する（未登録）
                """
        )
    }

    @Test("registrationLabel は登録済みなら「開発環境 / サービス」、未登録なら「未登録」")
    func registrationLabels() throws {
        let registered = try target(
            "demo", .running, .adopt, registration: registration("Demo", "DB")
        )
        let unregistered = try target("demo", .running, .adopt, registration: nil)
        #expect(registered.registrationLabel == "Demo / DB")
        #expect(unregistered.registrationLabel == "未登録")
    }

    @Test("managedStackObservationFailed の title と detail")
    func observationFailedText() {
        let reason = SwitchFailure.Reason.managedStackObservationFailed(
            types: [.supabase],
            details: ["Docker unavailable", "demo: status failed"]
        )
        #expect(reason.title == "Supabaseの状態を確認できない")
        #expect(
            reason.detail == """
                Supabaseスタックの状態を確定できませんでした。停止中とは判断できないため、変更操作へ進みません。
                Docker unavailable
                demo: status failed
                """
        )
    }

    @Test("managedStackStopFailed は停止済み・未処理が空なら「なし」、あれば ` / ` 区切り")
    func stopFailedText() throws {
        let empty = SwitchFailure.Reason.managedStackStopFailed(
            identity: try makeSupabaseIdentity("sample"), reason: "CLI failed", stopped: [], remaining: []
        )
        #expect(empty.title == "既存のSupabaseを停止できない")
        #expect(
            empty.detail == """
                既存のSupabase「sample」を停止できませんでした。
                CLI failed
                停止済み: なし
                未処理: なし
                停止済みのスタックは自動で再起動しません。
                """
        )

        let filled = SwitchFailure.Reason.managedStackStopFailed(
            identity: try makeSupabaseIdentity("sample"), reason: "CLI failed",
            stopped: ["a", "b"], remaining: ["c", "d"]
        )
        #expect(
            filled.detail == """
                既存のSupabase「sample」を停止できませんでした。
                CLI failed
                停止済み: a / b
                未処理: c / d
                停止済みのスタックは自動で再起動しません。
                """
        )
    }

    // MARK: - RuntimeError / 設定不備

    @Test("managedStartOwnershipUnconfirmed の description")
    func startOwnershipUnconfirmedText() throws {
        let error = RuntimeError.managedStartOwnershipUnconfirmed(
            stack: "Supabase",
            identity: try makeSupabaseIdentity("demo"),
            state: .running,
            reason: "起動前から稼働中でした。"
        )
        #expect(
            error.description
                == "サービス「Supabase」のSupabase「demo」は起動処理の前後で稼働中と観測されましたが、"
                + "Dev Switcherが起動したスタックか確定できません。"
                + "停止権限を持たないため自動停止していません。再度起動操作を行い、現在のスタックの扱いを確認してください。\n"
                + "起動前から稼働中でした。"
        )
    }

    @Test("Supabase設定の5種の不備は、それぞれ固有の理由で managedCommandInvalid になる")
    func configurationFailureReasons() throws {
        let directory = URL(fileURLWithPath: "/tmp/demo")
        let cases: [(String, LaunchUnit, String)] = [
            (
                "カスタム停止",
                supabaseService(
                    stop: CommandSpec(
                        executable: "/bin/echo", arguments: [], workingDirectory: directory
                    ),
                    directory: directory
                ),
                "Supabaseの終了コマンドは起動コマンドから導出するため、個別には指定できません。"
            ),
            (
                "未対応形式",
                supabaseService(arguments: ["start"], executable: "foo", directory: directory),
                "起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
            ),
            (
                "start欠落",
                supabaseService(arguments: ["status"], directory: directory),
                "起動コマンドに `start` サブコマンドがありません。"
            ),
            (
                "禁止オプション",
                supabaseService(arguments: ["start", "--all"], directory: directory),
                "起動コマンドに `--all` と `--no-backup` は指定できません。"
            ),
            (
                "workdir値欠落",
                supabaseService(arguments: ["start", "--workdir"], directory: directory),
                "`--workdir` にディレクトリが指定されていません。"
            ),
        ]

        for (name, service, expectedReason) in cases {
            let definition = try #require(service.managedStackDefinition, "\(name)")
            let workingDirectory = service.start.workingDirectory
            #expect(definition.configuration.derived(workingDirectory: workingDirectory) == nil, "\(name)")
            let failureReason = try #require(
                definition.configuration.structuralIssues(workingDirectory: workingDirectory)
                    .first?.failureReason,
                "\(name)"
            )
            #expect(failureReason == expectedReason, "\(name)")
            let error = RuntimeError.managedCommandInvalid(
                service: service.name,
                reason: failureReason
            )
            #expect(
                error.description == "サービス「Supabase」の管理コマンドを構成できません。\n" + expectedReason,
                "\(name)"
            )
        }
    }

    // MARK: - Operation / Command エラー

    @Test("ManagedStackOperationError 3ケースの description")
    func operationErrorText() throws {
        let demo = try makeSupabaseIdentity("demo")

        let failedWithOutput = ManagedStackOperationError.commandFailed(
            action: "開始", identity: demo, status: .exited(code: 2), output: "boom"
        )
        #expect(
            failedWithOutput.description
                == "Supabase「demo」の開始コマンドが失敗しました（終了コード 2）。\n直近の出力:\nboom"
        )
        let failedWithoutOutput = ManagedStackOperationError.commandFailed(
            action: "停止", identity: demo, status: .signaled(signal: 9), output: ""
        )
        #expect(
            failedWithoutOutput.description
                == "Supabase「demo」の停止コマンドが失敗しました（シグナル 9 で終了）。"
        )

        let unavailable = ManagedStackOperationError.commandUnavailable(
            action: "停止", identity: demo, reason: "supabase が見つかりません。"
        )
        #expect(
            unavailable.description
                == "Supabase「demo」の停止コマンドを実行できません。\nsupabase が見つかりません。"
        )

        let notConfirmedWithDetail = ManagedStackOperationError.stateNotConfirmed(
            action: "停止", identity: demo, expected: .notRunning, actual: .running, detail: "残存コンテナあり"
        )
        #expect(
            notConfirmedWithDetail.description
                == "Supabase「demo」の停止後に停止中を確認できませんでした（実測: 稼働中）。\n残存コンテナあり"
        )
        let notConfirmedWithoutDetail = ManagedStackOperationError.stateNotConfirmed(
            action: "開始", identity: demo, expected: .running, actual: .unknown, detail: nil
        )
        #expect(
            notConfirmedWithoutDetail.description
                == "Supabase「demo」の開始後に稼働中を確認できませんでした（実測: 判定不能）。"
        )
    }

    @Test("ManagedStackCommandError 2ケースの description")
    func commandErrorText() {
        #expect(
            ManagedStackCommandError.forbiddenOption(command: "supabase stop --all", option: "--all")
                .description == "`--all` は実行できません（supabase stop --all）。"
        )
        #expect(
            ManagedStackCommandError.unresolvable(command: "supabase start", reason: "not found")
                .description == "コマンド「supabase start」を実行できません。\nnot found"
        )
    }

    // MARK: - ラベルと rawValue

    @Test("状態・管理関係・操作の label と、管理関係の rawValue")
    func labelsAndRawValues() {
        #expect(ManagedStackState.notRunning.label == "停止中")
        #expect(ManagedStackState.running.label == "稼働中")
        #expect(ManagedStackState.degraded.label == "一部だけ稼働")
        #expect(ManagedStackState.unknown.label == "判定不能")

        #expect(ManagedStackRelationship.launched.label == "今回起動")
        #expect(ManagedStackRelationship.adopted.label == "引き継ぎ")
        #expect(ManagedStackRelationship.restored.label == "再検証済み")
        #expect(ManagedStackRelationship.launched.rawValue == "launched")
        #expect(ManagedStackRelationship.adopted.rawValue == "adopted")
        #expect(ManagedStackRelationship.restored.rawValue == "restored")

        #expect(ManagedStackConfirmationTarget.Action.adopt.label == "引き継ぐ")
        #expect(ManagedStackConfirmationTarget.Action.restart.label == "停止して起動し直す")
        #expect(ManagedStackConfirmationTarget.Action.stop.label == "停止する")
        #expect(ManagedStackConfirmationTarget.Action.start.label == "起動する")
    }

    // MARK: - ManagedStackSnapshot の意味

    @Test("観測失敗のスナップショットは、未列挙のIDも unknown にし、理由を1件だけ返す")
    func unobservableSnapshot() throws {
        let snapshot = ManagedStackSnapshot(type: .supabase, unobservable: "Docker unavailable")
        let anyID = try makeSupabaseIdentity("never-listed")

        #expect(snapshot.observations.isEmpty)
        #expect(snapshot.failure(of: .supabase) == "Docker unavailable")
        #expect(snapshot.state(of: anyID) == .unknown)
        #expect(snapshot.observation(of: anyID).detail == "Docker unavailable")
        #expect(snapshot.hasUnknown)
        #expect(snapshot.failureDetails == ["Docker unavailable"])
    }

    @Test("観測成功のスナップショットは、未列挙のIDを notRunning（detail なし）にする")
    func observedSnapshotTreatsUnlistedAsNotRunning() throws {
        let snapshot = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("demo"), state: .running),
        ])
        let unlisted = snapshot.observation(of: try makeSupabaseIdentity("sample"))

        #expect(unlisted.state == .notRunning)
        #expect(unlisted.detail == nil)
        #expect(snapshot.state(of: try makeSupabaseIdentity("demo")) == .running)
        #expect(snapshot.hasUnknown == false)
        #expect(snapshot.failureDetails.isEmpty)
        #expect(ManagedStackSnapshot(type: .supabase, observations: []).hasUnknown == false)
    }

    @Test("観測の中に unknown があれば hasUnknown になり、failureDetails は「ID: 理由」を返す")
    func snapshotWithUnknownObservations() throws {
        let snapshot = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("sample"), state: .unknown, detail: "ラベル欠落"),
            ManagedStackObservation(identity: try makeSupabaseIdentity("demo"), state: .running),
            ManagedStackObservation(identity: try makeSupabaseIdentity("legacy"), state: .unknown),
        ])

        #expect(snapshot.hasUnknown)
        #expect(snapshot.observations.filter { $0.state == .unknown }.map(\.identity.value) == ["legacy", "sample"])
        // IDの昇順で並び、理由が無ければ固定文言になる。
        #expect(
            snapshot.failureDetails == [
                "legacy: 理由を取得できませんでした。",
                "sample: ラベル欠落",
            ]
        )
        #expect(snapshot.observations.map(\.identity.value) == ["demo", "legacy", "sample"])
    }

    @Test("detail だけが違う観測は等しく、状態が違えば等しくない")
    func observationEquality() throws {
        let demo = try makeSupabaseIdentity("demo")
        #expect(
            ManagedStackObservation(identity: demo, state: .degraded, detail: "A")
                == ManagedStackObservation(identity: demo, state: .degraded, detail: "B")
        )
        #expect(
            ManagedStackSnapshot(type: .supabase, observations: [
                ManagedStackObservation(identity: demo, state: .degraded, detail: "A"),
            ]) == ManagedStackSnapshot(type: .supabase, observations: [
                ManagedStackObservation(identity: demo, state: .degraded, detail: nil),
            ])
        )
        #expect(
            ManagedStackObservation(identity: demo, state: .degraded)
                != ManagedStackObservation(identity: demo, state: .running)
        )
    }

    // MARK: - ManagedStackConfirmationPlan

    @Test("requiresConfirmation は「新規起動のみで他スタックに触れない」場合だけ false")
    func requiresConfirmationCondition() throws {
        let stopTarget = try target("sample", .running, .stop, registration: nil)

        for action in [
            ManagedStackConfirmationTarget.Action.adopt, .restart, .stop,
        ] {
            let alone = plan(target: try target("demo", .running, action, registration: registration("Demo")))
            #expect(alone.requiresConfirmation, "\(action)")
        }

        let startOnly = plan(target: try target("demo", .notRunning, .start, registration: registration("Demo")))
        #expect(startOnly.requiresConfirmation == false)

        let startWithStop = plan(
            target: try target("demo", .notRunning, .start, registration: registration("Demo")),
            stopTargets: [stopTarget]
        )
        #expect(startWithStop.requiresConfirmation)
    }

    @Test("registration だけが違う2つの plan の approval は等しい")
    func approvalIgnoresRegistration() throws {
        let serviceID = UUID()
        let withRegistration = plan(
            serviceID: serviceID,
            target: try target("demo", .running, .adopt, registration: registration("Demo")),
            stopTargets: [try target("sample", .running, .stop, registration: registration("Sample"))]
        )
        let withoutRegistration = plan(
            serviceID: serviceID,
            target: try target("demo", .running, .adopt, registration: registration("Cat", "DB")),
            stopTargets: [try target("sample", .running, .stop, registration: nil)]
        )

        #expect(withRegistration != withoutRegistration)
        #expect(withRegistration.approval == withoutRegistration.approval)
        #expect(withRegistration.approval.entries.dropFirst().map(\.identity.value) == ["sample"])
        #expect(withRegistration.approval.entries.first?.action == .adopt)
    }
}
