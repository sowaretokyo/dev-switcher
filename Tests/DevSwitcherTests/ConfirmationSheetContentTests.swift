@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 確認シートの見出し説明・notes・行の表示文字列を固定する。
/// 期待値は現行ソースから写した文字列リテラルで、実装と同じ計算では作らない。
@Suite("確認シートの文言")
struct ConfirmationSheetContentTests {
    private func registration(_ projectName: String, _ serviceName: String) -> ManagedStackConfirmationTarget.Registration {
        ManagedStackConfirmationTarget.Registration(
            environmentName: projectName,
            stackName: serviceName,
            directory: URL(fileURLWithPath: "/tmp/\(projectName.lowercased())")
        )
    }

    private func plan(
        action: ManagedStackConfirmationTarget.Action,
        withStopTargets: Bool
    ) throws -> ManagedStackConfirmationPlan {
        let directory = URL(fileURLWithPath: "/tmp/demo")
        let serviceID = UUID()
        let stopTargets = withStopTargets
            ? [
                ManagedStackConfirmationTarget(
                    stackID: nil,
                    identity: try makeSupabaseIdentity("sample"),
                    state: .running,
                    action: .stop,
                    registration: registration("Sample", "DB")
                ),
                ManagedStackConfirmationTarget(
                    stackID: nil,
                    identity: try makeSupabaseIdentity("legacy"),
                    state: .degraded,
                    action: .stop,
                    registration: nil
                ),
            ]
            : []
        return ManagedStackConfirmationPlan(
            environmentName: "Demo",
            entries: [
                ManagedStackConfirmationTarget(
                    stackID: serviceID,
                    identity: try makeSupabaseIdentity("demo"),
                    state: .running,
                    action: action,
                    registration: registration("Demo", "Supabase")
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
    }

    private let lead = "開発環境「Demo」のサービス「Supabase」を起動する前に、既存のローカルSupabaseスタックの扱いを決めてください。"
    private let cancelNote = "キャンセルした場合、既存スタック・切替元・切替先のいずれも変更しません。"
    private let stopNotes = [
        "停止は `project_id` を1件ずつ指定して実行します（`--all` と `--no-backup` は使いません）。",
        "停止後に対象の起動が失敗しても、停止したスタックは自動で再起動しません。",
    ]

    @Test("見出し説明は開発環境名とサービス名を含む")
    func leadText() throws {
        for action in [ManagedStackConfirmationTarget.Action.adopt, .restart, .start, .stop] {
            let content = ConfirmationSheetContent(plan: try plan(action: action, withStopTargets: false))
            #expect(content.lead == lead, "\(action)")
        }
    }

    @Test("notes は action と停止行の有無で決まる")
    func notes() throws {
        let adoptNotes = [
            "引き継いだあとは、Dev Switcherから停止・切替できます。",
            "現在のスタックへ起動コマンドの `--exclude` などは再適用しません。",
        ]
        let restartNotes = ["対象の `project_id` だけを停止し、停止を確認してから起動し直します。"]
        let freshNotes = ["対象は新しく起動します。"]

        let expected: [(ManagedStackConfirmationTarget.Action, [String])] = [
            (.adopt, adoptNotes), (.restart, restartNotes), (.start, freshNotes), (.stop, freshNotes),
        ]
        for (action, head) in expected {
            let alone = ConfirmationSheetContent(plan: try plan(action: action, withStopTargets: false))
            let extra = action == .restart ? ["停止後に対象の起動が失敗しても、停止したスタックは自動で再起動しません。"] : []
            #expect(alone.notes == head + [cancelNote] + extra, "\(action) 停止行なし")

            let withStops = ConfirmationSheetContent(plan: try plan(action: action, withStopTargets: true))
            #expect(withStops.notes == head + stopNotes + [cancelNote], "\(action) 停止行あり")
        }
    }

    @Test("行は対象→停止対象の順で、登録の有無と状態・操作を文字列で持つ")
    func rows() throws {
        let content = ConfirmationSheetContent(plan: try plan(action: .adopt, withStopTargets: true))
        #expect(
            content.rows == [
                .init(
                    identity: "Supabase / demo", registration: "Demo / Supabase",
                    configDirectory: "/tmp/demo", state: "稼働中", action: "引き継ぐ"
                ),
                .init(
                    identity: "Supabase / sample", registration: "Sample / DB",
                    configDirectory: "/tmp/sample", state: "稼働中", action: "停止する"
                ),
                .init(
                    identity: "Supabase / legacy", registration: "未登録",
                    configDirectory: nil, state: "一部だけ稼働", action: "停止する"
                ),
            ]
        )
    }

    @Test("4つの action ごとの対象行の操作ラベル")
    func actionLabels() throws {
        let expected: [(ManagedStackConfirmationTarget.Action, String)] = [
            (.adopt, "引き継ぐ"), (.restart, "停止して起動し直す"), (.stop, "停止する"), (.start, "起動する"),
        ]
        for (action, label) in expected {
            let content = ConfirmationSheetContent(plan: try plan(action: action, withStopTargets: false))
            #expect(content.rows.map(\.action) == [label], "\(action)")
        }
    }

    @Test("起動先が Supabase でも停止する Compose の全 profile を明示する")
    func mixedStackStopScope() throws {
        for action in [ManagedStackConfirmationTarget.Action.start, .restart] {
            let original = try plan(action: action, withStopTargets: false)
            let compose = ManagedStackConfirmationTarget(stackID: nil,
                identity: try ManagedStackIdentity(type: .dockerCompose, value: "shop"),
                state: .running, action: .stop, registration: registration("Shop", "DB"))
            let mixed = ManagedStackConfirmationPlan(environmentName: original.environmentName,
                entries: original.entries + [compose], snapshot: original.snapshot,
                fingerprints: original.fingerprints)
            let content = ConfirmationSheetContent(plan: mixed)
            #expect(content.notes.contains("同じプロジェクト名の全 profile を停止します。設定した profile 以外も対象です。コンテナやボリュームは削除しません。"))
            #expect(content.rows.last?.identity == "Docker Compose / shop")
        }
    }

    @Test("複数対象でも種類ごとの説明・停止範囲・注意書きを重複なく表示する",
          arguments: [ManagedStackConfirmationTarget.Action.adopt, .restart, .start])
    func multipleTargetNotes(_ action: ManagedStackConfirmationTarget.Action) throws {
        let directory = URL(fileURLWithPath: "/tmp/demo")
        let composeID = UUID()
        let compose = ManagedStackConfirmationTarget(stackID: composeID,
            identity: try ManagedStackIdentity(type: .dockerCompose, value: "shop"),
            state: action == .restart ? .degraded : .running, action: action,
            registration: registration("Demo", "Compose"))
        let composeScope = "同じプロジェクト名の全 profile を停止します。設定した profile 以外も対象です。コンテナやボリュームは削除しません。"
        for withStops in [false, true] {
            let original = try plan(action: action, withStopTargets: withStops)
            var fingerprints = original.fingerprints
            fingerprints[composeID] = .dockerCompose(.init(workingDirectory: directory,
                projectName: "shop", files: [directory.appendingPathComponent("compose.yaml")],
                profiles: ["dev"], upArguments: []))
            let mixed = ManagedStackConfirmationPlan(environmentName: original.environmentName,
                entries: [original.primaryEntry, compose] + original.stopEntries,
                snapshot: original.snapshot, fingerprints: fingerprints)
            let content = ConfirmationSheetContent(plan: mixed)
            var expected: [String]
            switch action {
            case .adopt:
                expected = [
                    "引き継いだあとは、Dev Switcherから停止・切替できます。",
                    "現在のスタックへ起動時の追加引数や profile の設定を再適用しません。引き継いだ後の停止は、同じプロジェクト名の全 profile が対象です。",
                    "現在のスタックへ起動コマンドの `--exclude` などは再適用しません。",
                ]
            case .restart:
                expected = withStops ? [] : [stopNotes[1]]
                expected += [composeScope, stopNotes[0]]
            case .start:
                expected = ["「起動する」の行だけを新しく起動します。"]
            case .stop:
                Issue.record("起動先の操作は stop にしません。")
                return
            }
            if withStops {
                if action != .restart { expected.append(stopNotes[0]) }
                expected.append(stopNotes[1])
            }
            expected.append(cancelNote)
            #expect(content.notes == expected)
            #expect(content.rows.map(\.identity).prefix(2) == ["Supabase / demo", "Docker Compose / shop"])
        }
    }
}
