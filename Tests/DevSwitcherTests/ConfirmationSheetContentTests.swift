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
        let directory = URL(fileURLWithPath: "/tmp/bell")
        let serviceID = UUID()
        let stopTargets = withStopTargets
            ? [
                ManagedStackConfirmationTarget(
                    stackID: nil,
                    identity: try makeSupabaseIdentity("penta"),
                    state: .running,
                    action: .stop,
                    registration: registration("Penta", "DB")
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
            environmentName: "Bell",
            entries: [
                ManagedStackConfirmationTarget(
                    stackID: serviceID,
                    identity: try makeSupabaseIdentity("bell"),
                    state: .running,
                    action: action,
                    registration: registration("Bell", "Supabase")
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

    private let lead = "開発環境「Bell」のサービス「Supabase」を起動する前に、既存のローカルSupabaseスタックの扱いを決めてください。"
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
            #expect(alone.notes == head + [cancelNote], "\(action) 停止行なし")

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
                    identity: "bell", registration: "Bell / Supabase",
                    configDirectory: "/tmp/bell", state: "稼働中", action: "引き継ぐ"
                ),
                .init(
                    identity: "penta", registration: "Penta / DB",
                    configDirectory: "/tmp/penta", state: "稼働中", action: "停止する"
                ),
                .init(
                    identity: "legacy", registration: "未登録",
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
}
