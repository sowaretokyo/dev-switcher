@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 画面状態（`AppState`）が組み立てる管理対象スタックの表示値を固定する特性テスト。
/// SwiftUI ビュー内の文言はここでは扱わない。保存先・実行環境・Docker・CLI は一時ディレクトリと
/// 差し替え用の世界に閉じ、利用者の Application Support にも実Dockerにも触れない。
@Suite("管理対象スタックの表示値の特性")
@MainActor
struct ManagedStackPresentationCharacterizationTests {
    private func supabaseProject(
        name: String = "Demo",
        projectID: String = "demo",
        directory: URL,
        arguments: [String] = ["start"]
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: projectID, in: directory)
        return ProjectDefinition(
            name: name,
            color: .blue,
            directory: directory,
            services: [makeAppStateSupabaseService(workingDirectory: directory, arguments: arguments)]
        )
    }

    // MARK: - ManagedStackConfirmationPresentation

    private func presentation(
        action: ManagedStackConfirmationTarget.Action,
        withStopTargets: Bool
    ) throws -> AppState.ManagedStackConfirmationPresentation {
        let directory = URL(fileURLWithPath: "/tmp/demo")
        let stopTargets = withStopTargets
            ? [
                ManagedStackConfirmationTarget(
                    stackID: nil, identity: try makeSupabaseIdentity("sample"), state: .running, action: .stop,
                    registration: nil
                ),
            ]
            : []
        let serviceID = UUID()
        let plan = ManagedStackConfirmationPlan(
            environmentName: "Demo",
            entries: [
                ManagedStackConfirmationTarget(
                    stackID: serviceID, identity: try makeSupabaseIdentity("demo"), state: .running, action: action,
                    registration: .init(
                        environmentName: "Demo", stackName: "Supabase", directory: directory
                    )
                ),
            ] + stopTargets,
            snapshot: ManagedStackSnapshot(type: .supabase, observations: []),
            fingerprints: [
                serviceID: .supabase(
                    SupabaseLifecycleFingerprint(
                        start: CommandSpec(
                            executable: "supabase", arguments: ["start"], workingDirectory: directory
                        ),
                        configDirectory: directory
                    )
                ),
            ]
        )
        return AppState.ManagedStackConfirmationPresentation(projectID: UUID(), plan: plan)
    }

    @Test("確認シートの title と confirmButtonTitle は操作ごとに決まる")
    func confirmationTitles() throws {
        let adopt = try presentation(action: .adopt, withStopTargets: false)
        #expect(adopt.title == "既存のSupabaseを引き継ぎますか？")
        #expect(adopt.confirmButtonTitle == "引き継ぐ")

        let restart = try presentation(action: .restart, withStopTargets: false)
        #expect(restart.title == "既存のSupabaseを復旧しますか？")
        #expect(restart.confirmButtonTitle == "停止して起動し直す")

        for action in [ManagedStackConfirmationTarget.Action.start, .stop] {
            let other = try presentation(action: action, withStopTargets: true)
            #expect(other.title == "既存のSupabaseを停止して切り替えますか？", "\(action)")
            #expect(other.confirmButtonTitle == "停止して切り替える", "\(action)")
        }
    }

    @Test("isDestructive は、引き継ぎだけで他スタックを止めない場合に限り false")
    func confirmationIsDestructive() throws {
        #expect(try presentation(action: .adopt, withStopTargets: false).isDestructive == false)
        #expect(try presentation(action: .adopt, withStopTargets: true).isDestructive)
        for action in [
            ManagedStackConfirmationTarget.Action.restart, .start, .stop,
        ] {
            #expect(try presentation(action: action, withStopTargets: false).isDestructive, "\(action)")
            #expect(try presentation(action: action, withStopTargets: true).isDestructive, "\(action)")
        }
    }

    // MARK: - ManagedStackUIState.label

    @Test("ManagedStackUIState.label は外部なら「外部・」を付け、管理下なら状態だけを出す")
    func uiStateLabel() throws {
        let demo = try makeSupabaseIdentity("demo")
        let external = AppState.ManagedStackUIState(
            identity: demo, state: .running, relationship: nil, detail: nil
        )
        #expect(external.isExternal)
        #expect(external.label == "外部・稼働中")

        let externalDegraded = AppState.ManagedStackUIState(
            identity: demo, state: .degraded, relationship: nil, detail: nil
        )
        #expect(externalDegraded.label == "外部・一部だけ稼働")

        let managed = AppState.ManagedStackUIState(
            identity: demo, state: .running, relationship: .launched, detail: nil
        )
        #expect(managed.isExternal == false)
        #expect(managed.label == "稼働中")

        // 停止中は外部扱いにしない。ID不明（解決失敗）も同様。
        let notRunning = AppState.ManagedStackUIState(
            identity: demo, state: .notRunning, relationship: nil, detail: nil
        )
        #expect(notRunning.label == "停止中")
        let unresolved = AppState.ManagedStackUIState(
            identity: nil, state: .unknown, relationship: nil, detail: "x"
        )
        #expect(unresolved.label == "判定不能")
    }

    // MARK: - supabaseUIState の detail

    @Test("設定ファイルが無ければ、project_id なし・判定不能で、設定ファイルの欠落を detail に出す")
    func uiStateDetailForMissingConfig() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        // 保存後に設定ファイルを失った状態（保存時は検証で弾かれるため、保存してから消す）。
        try FileManager.default.removeItem(at: directory.appendingPathComponent("supabase"))
        let state = makeAppState(directory: directory)

        await state.bootstrap()

        let serviceID = try #require(project.launchUnits.first?.id)
        let ui = try #require(state.state(of: serviceID).managedStack)
        #expect(ui.identity == nil)
        #expect(ui.state == .unknown)
        #expect(ui.relationship == nil)
        #expect(
            ui.detail == "Supabaseの設定ファイルがありません（\(directory.standardizedFileURL.path)/supabase/config.toml）。"
        )
    }

    // 起動コマンドの構造不備（`managedCommandInvalid` を detail に出す経路）は、
    // 読み込み時に構造検証が弾くため、保存済みの開発環境からは到達できない。ここでは固定できない。

    @Test("環境を取得できず観測が始まっていなければ、「まだ観測できていません」を detail に出す")
    func uiStateDetailBeforeFirstObservation() async throws {
        struct EnvironmentFailure: Error, CustomStringConvertible {
            var description: String { "環境取得に失敗" }
        }
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(
            directory: directory,
            environmentLoader: { throw EnvironmentFailure() }
        )

        await state.bootstrap()

        let serviceID = try #require(project.launchUnits.first?.id)
        let ui = try #require(state.state(of: serviceID).managedStack)
        #expect(ui.identity?.value == "demo")
        #expect(ui.state == .unknown)
        #expect(ui.relationship == nil)
        #expect(ui.detail == "Supabaseの状態をまだ観測できていません。")
    }

    @Test("観測できた外部スタックは、観測側の detail をそのまま出す")
    func uiStateDetailFromObservation() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let world = FakeSupabaseWorld(stacks: ["demo": .degraded(reason: "DBコンテナが exited 状態です。")])
        let state = makeAppState(directory: directory, supabaseWorld: world)
        await state.bootstrap()
        let serviceID = try #require(project.launchUnits.first?.id)

        let degraded = try #require(state.state(of: serviceID).managedStack)
        #expect(degraded.label == "外部・一部だけ稼働")
        #expect(degraded.detail == "DBコンテナが exited 状態です。")

        await world.failInventory("Docker unavailable")
        await state.applicationDidBecomeActive()
        let unknown = try #require(state.state(of: serviceID).managedStack)
        #expect(unknown.label == "外部・判定不能")
        #expect(unknown.detail == "Docker unavailable")
    }

    // MARK: - restartBlockedReason

    @Test("Supabaseの再起動は専用の理由で拒否し、操作を試すと operationError に同じ理由を出す")
    func restartBlockedReasonForSupabase() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let service = try #require(project.launchUnits.first)

        let reason = "Supabaseは専用の停止・状態確認を使うため、単体の起動・再起動はできません。"
        #expect(state.restartBlockedReason(for: service, in: project) == reason)
        #expect(state.canRestart(service, in: project) == false)

        state.restart(service, in: project)
        #expect(state.operationError == "Supabase を再起動できません。\n" + reason)
    }

    @Test("登録内容と違う定義、停止中の開発環境の通常プロセスにも固有の理由を返す")
    func restartBlockedReasonForOrdinaryService() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([project])
        let state = makeAppState(directory: directory)
        await state.bootstrap()
        let service = try #require(project.launchUnits.first)

        #expect(
            state.restartBlockedReason(for: service, in: project)
                == "停止中の開発環境は、開発環境単位で起動してください。"
        )

        var edited = project
        edited.name = "Demo (edited)"
        #expect(
            state.restartBlockedReason(for: service, in: edited)
                == "対象のプロセス設定が現在の登録内容と一致しません。"
        )
    }

    // MARK: - managedHintError

    @Test("旧形式の手掛かりは「サービス名: 理由」を managedHintError に出し、廃棄の導線を残す")
    func managedHintErrorForLegacyHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        let json = """
            {
              "schemaVersion": 5,
              "hints": [],
              "legacyHints": [],
              "managedHints": [{
                "projectID": "\(project.id.uuidString)",
                "serviceID": "\(service.id.uuidString)",
                "serviceName": "Supabase"
              }]
            }
            """
        try Data(json.utf8).write(to: RuntimeHintStore(directory: directory).fileURL)
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        let state = makeAppState(directory: directory, supabaseWorld: world)

        await state.bootstrap()

        #expect(
            state.managedHintError
                == "Supabase: 旧形式の手掛かりには`project_id`と設定の記録がないため、状態確認コマンドを実行しません。"
        )
        #expect(state.hasDiscardableManagedHints)
    }

    @Test("保存時と設定が違う手掛かりは「サービス名: 理由」を managedHintError に出す")
    func managedHintErrorForMismatchedHint() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        let hint = try #require(
            makeManagedStackHint(
                projectID: project.id, service: service,
                supabaseProjectID: try makeSupabaseProjectID("demo"), relationship: .launched
            )
        )
        try RuntimeHintStore(directory: directory).save([], legacy: [], managed: [hint])
        // 保存後に config.toml の project_id だけが変わった。
        try writeSupabaseConfig(projectID: "sample", in: directory)
        let state = makeAppState(
            directory: directory,
            supabaseWorld: FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        )

        await state.bootstrap()

        #expect(
            state.managedHintError
                == "Supabase: 保存時の設定ディレクトリ・起動コマンド・`project_id`と一致しないため、状態確認コマンドを実行しません。"
        )
    }

    @Test("対応するSupabase設定が無い手掛かりは、その旨を managedHintError に出し、起動を止める理由を返す")
    func managedHintErrorForMissingDefinition() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = makeWorkerProject(directory: directory)
        try ProjectStore(directory: directory).save([worker])
        try writeSupabaseConfig(projectID: "demo", in: directory)
        let orphanService = makeAppStateSupabaseService(workingDirectory: directory)
        let orphan = try #require(
            makeManagedStackHint(
                projectID: UUID(), service: orphanService,
                supabaseProjectID: try makeSupabaseProjectID("demo"), relationship: .adopted
            )
        )
        try RuntimeHintStore(directory: directory).save([], legacy: [], managed: [orphan])
        let state = makeAppState(directory: directory)

        await state.bootstrap()

        #expect(
            state.managedHintError
                == "Supabase: 対応するSupabase設定が見つからないため状態を確認できません。"
        )
        #expect(
            state.startBlockedReason
                == "状態を判定できない管理対象スタックの手掛かりが残っています。"
                + "画面上部の案内から再試行するか、設定が無い手掛かりを破棄してください。"
        )
        #expect(state.canStart == false)
    }

    // MARK: - v6 リテラルの手掛かりからの起動

    /// schema v6 の手掛かりファイルを、リテラルの形で書き出す。
    private func writeV6Hint(
        project: ProjectDefinition,
        service: LaunchUnit,
        stackID: String,
        relationship: String,
        directory: URL
    ) throws {
        let configuration = try #require(service.derivedSupabaseConfiguration)
        let workingDirectory = configuration.fingerprint.startWorkingDirectory.absoluteString
        let configDirectory = configuration.configDirectory.absoluteString
        let json = """
            {
              "schemaVersion": 6,
              "hints": [],
              "legacyHints": [],
              "managedHints": [{
                "projectID": "\(project.id.uuidString)",
                "serviceID": "\(service.id.uuidString)",
                "serviceName": "Supabase",
                "supabaseProjectID": "\(stackID)",
                "configDirectory": "\(configDirectory)",
                "fingerprint": {
                  "executable": "supabase",
                  "startArguments": ["start"],
                  "startWorkingDirectory": "\(workingDirectory)",
                  "configDirectory": "\(configDirectory)"
                },
                "relationship": "\(relationship)"
              }]
            }
            """
        try Data(json.utf8).write(to: RuntimeHintStore(directory: directory).fileURL)
    }

    @Test("v6 の手掛かりで running を再検証できれば、restored・起動済みで復元する")
    func bootstrapRestoresRunningFromV6Literal() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        try writeV6Hint(
            project: project, service: service, stackID: "demo", relationship: "launched", directory: directory
        )
        let world = FakeSupabaseWorld(stacks: ["demo": .databaseHealthy])
        let state = makeAppState(directory: directory, supabaseWorld: world)

        await state.bootstrap()

        let ui = try #require(state.state(of: service.id).managedStack)
        #expect(ui.relationship == .restored)
        #expect(ui.state == .running)
        #expect(ui.label == "稼働中")
        #expect(state.state(of: service.id).phase == .healthy)
        #expect(state.hasManagedResources(in: project))
        #expect(state.managedHintError == nil)
        // 再検証は status だけ。start も stop も実行しない。
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
    }

    @Test("v6 の手掛かりで degraded を再検証すると、restored・残存あり・停止導線ありで復元する")
    func bootstrapRestoresDegradedFromV6Literal() async throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try supabaseProject(directory: directory)
        let service = try #require(project.launchUnits.first)
        try ProjectStore(directory: directory).save([project])
        try writeV6Hint(
            project: project, service: service, stackID: "demo", relationship: "adopted", directory: directory
        )
        let world = FakeSupabaseWorld(stacks: ["demo": .degraded(reason: "DBコンテナがありません")])
        let state = makeAppState(directory: directory, supabaseWorld: world)

        await state.bootstrap()

        let ui = try #require(state.state(of: service.id).managedStack)
        #expect(ui.relationship == .restored)
        #expect(ui.state == .degraded)
        #expect(ui.detail == "DBコンテナがありません")
        #expect(state.state(of: service.id).phase == .residual)
        #expect(state.hasManagedResources(in: project))
        #expect(state.stopBlockedReason == nil)
        #expect(state.managedHintError == nil)
        #expect(await world.commandLines.allSatisfy { $0.contains("status") })
    }
}
