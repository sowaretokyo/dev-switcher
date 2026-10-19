import DevSwitcherCore
import Foundation

/// 確認シートに出す文言を、View の外で組み立てる純粋な値。
/// 文言の変更を単体テストで検出できるようにするため、SwiftUI に依存させない。
struct ConfirmationSheetContent: Equatable {
    /// 対象スタックの1行ぶんの表示文字列。
    struct Row: Equatable, Identifiable {
        let identity: String
        var id: String { identity }
        let registration: String
        let configDirectory: String?
        let state: String
        let action: String
    }

    /// 見出しの下の説明文。
    let lead: String
    let rows: [Row]
    /// 何が起き、何が起きないかを明示する。既定へ倒した挙動を黙って実行しない。
    let notes: [String]

    init(plan: ManagedStackConfirmationPlan) {
        let primary = plan.primaryEntry
        let typeName = primary.identity.type.displayName
        let identityLabel = primary.identity.type.identityLabel
        let presentation = ManagedStackTypePresentation(primary.identity.type)
        lead = "開発環境「\(plan.environmentName)」のサービス「\(plan.primaryStackName)」を起動する前に、"
            + "既存のローカル\(typeName)スタックの扱いを決めてください。"
        rows = plan.entries.map(Self.row(for:))

        var notes: [String] = []
        switch primary.action {
        case .adopt:
            notes.append("引き継いだあとは、Dev Switcherから停止・切替できます。")
            if let limitation = presentation.adoptionLimitationNote {
                notes.append(limitation)
            }
        case .restart:
            notes.append("対象の \(identityLabel) だけを停止し、停止を確認してから起動し直します。")
        case .start, .stop:
            notes.append("対象は新しく起動します。")
        }
        if !plan.stopEntries.isEmpty {
            notes.append(presentation.stopScopeNote)
            notes.append("停止後に対象の起動が失敗しても、停止したスタックは自動で再起動しません。")
        }
        notes.append("キャンセルした場合、既存スタック・切替元・切替先のいずれも変更しません。")
        self.notes = notes
    }

    private static func row(for target: ManagedStackConfirmationTarget) -> Row {
        Row(
            identity: target.identity.value,
            registration: target.registrationLabel,
            configDirectory: target.registration?.directory.path,
            state: target.state.label,
            action: target.action.label
        )
    }
}
