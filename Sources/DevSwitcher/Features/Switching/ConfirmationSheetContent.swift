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

    private static var adoptionNote: String { L10n.text("引き継いだあとは、Dev Switcherから停止・切替できます。") }
    private static var noAutomaticRestartNote: String { L10n.text("停止後に対象の起動が失敗しても、停止したスタックは自動で再起動しません。") }
    private static var cancelNote: String { L10n.text("キャンセルした場合、既存スタック・切替元・切替先のいずれも変更しません。") }

    init(plan: ManagedStackConfirmationPlan) {
        let multipleTargets = plan.entries.filter { $0.action != .stop }.count > 1
        if multipleTargets {
            lead = L10n.text("開発環境「\(plan.environmentName)」の起動前に、以下の管理対象スタックの扱いを確認してください。")
            notes = Self.multipleTargetNotes(plan)
        } else {
            let typeName = plan.primaryEntry.identity.type.displayName
            lead = L10n.text("""
                開発環境「\(plan.environmentName)」のサービス「\(plan.primaryStackName)」を起動する前に、\
                既存のローカル\(typeName)スタックの扱いを決めてください。
                """)
            notes = Self.singleTargetNotes(plan)
        }
        rows = plan.entries.map(Self.row(for:))
    }

    private static func singleTargetNotes(_ plan: ManagedStackConfirmationPlan) -> [String] {
        let primary = plan.primaryEntry
        let presentation = ManagedStackTypePresentation(primary.identity.type)
        var notes: [String] = []
        switch primary.action {
        case .adopt:
            notes.append(adoptionNote)
            if let limitation = presentation.adoptionLimitationNote {
                notes.append(limitation)
            }
        case .restart:
            notes.append(L10n.text("対象の \(primary.identity.type.identityLabel) だけを停止し、停止を確認してから起動し直します。"))
        case .start, .stop:
            notes.append(L10n.text("対象は新しく起動します。"))
        }
        if !plan.stopEntries.isEmpty {
            notes += stopScopeNotes(for: plan.stopEntries)
            notes.append(noAutomaticRestartNote)
        }
        notes.append(cancelNote)
        if primary.action == .restart {
            if plan.stopEntries.isEmpty {
                notes.append(noAutomaticRestartNote)
            }
            if primary.identity.type == .dockerCompose,
               !plan.stopEntries.contains(where: { $0.identity.type == .dockerCompose }) {
                notes.append(presentation.stopScopeNote)
            }
        }
        return notes
    }

    private static func multipleTargetNotes(_ plan: ManagedStackConfirmationPlan) -> [String] {
        var notes: [String] = []
        let adopted = plan.entries.filter { $0.action == .adopt }
        if !adopted.isEmpty {
            notes.append(adoptionNote)
            notes += types(in: adopted).compactMap { ManagedStackTypePresentation($0).adoptionLimitationNote }
        }
        if plan.entries.contains(where: { $0.action == .start }) {
            notes.append(L10n.text("「起動する」の行だけを新しく起動します。"))
        }
        if plan.entries.contains(where: { $0.action == .restart }), plan.stopEntries.isEmpty {
            notes.append(noAutomaticRestartNote)
        }
        notes += stopScopeNotes(for: plan.entries.filter { $0.action == .stop || $0.action == .restart })
        if plan.entries.contains(where: { $0.action == .stop }) {
            notes.append(noAutomaticRestartNote)
        }
        notes.append(cancelNote)
        return notes
    }

    private static func types(in entries: [ManagedStackConfirmationTarget]) -> [ManagedStackType] {
        Set(entries.map { $0.identity.type }).sorted { $0.rawValue < $1.rawValue }
    }

    private static func stopScopeNotes(for entries: [ManagedStackConfirmationTarget]) -> [String] {
        types(in: entries).map { ManagedStackTypePresentation($0).stopScopeNote }
    }

    private static func row(for target: ManagedStackConfirmationTarget) -> Row {
        Row(
            identity: "\(target.identity.type.displayName) / \(target.identity.value)",
            registration: target.registrationLabel,
            configDirectory: target.registration?.directory.path,
            state: target.state.label,
            action: target.action.label
        )
    }
}
