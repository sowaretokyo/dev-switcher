import DevSwitcherCore

/// 開発環境に対して主に出す操作。詳細ペインとツールバーの両方がこの判定を使う。
///
/// 停止を出すかは表示状態ではなく、止められる資源があるかで決める
/// （`AppState.hasManagedResources(in:)`）。表示が「失敗」でも管理中のプロセスが
/// 残っていれば、必要なのは起動ではなく停止になる。判定を1か所に置き、
/// 詳細とツールバーの片方にだけ停止が出る状態を作らない。
enum ProjectPrimaryControl: Equatable {
    case inProgress(AppState.InlineOperation)
    case stop
    case start
    /// 表示上は動作中だが、Dev Switcher が止められる資源がない。押せる操作を出さない。
    case noAction
}

extension AppState {
    func primaryControl(for project: ProjectDefinition) -> ProjectPrimaryControl {
        if let operation = inlineOperation, operation.projectID == project.id {
            return .inProgress(operation)
        }
        if hasManagedResources(in: project) {
            return .stop
        }
        if phase(of: project).isActive {
            return .noAction
        }
        return .start
    }
}
