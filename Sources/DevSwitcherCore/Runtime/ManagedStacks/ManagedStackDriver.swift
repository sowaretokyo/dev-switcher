import Foundation

/// 種類ごとの観測・起動・対象限定停止（docs/ARCHITECTURE.md 4.2）。
///
/// 状態を変更するのは`start`と`stop`だけで、`observe`は読み取り専用。
/// 停止してよいかどうかは呼び出し側の管理関係が決める。driver は停止権限を持たない。
public protocol ManagedStackDriver: Sendable {
    var type: ManagedStackType { get }

    /// `known`は設定が分かっているスタック。conflictScope が allOfType の実装は、
    /// known に無いスタックも列挙して返す。identityOnly の実装は known だけを観測する。
    /// 返す snapshot は`type`の種類の結果だけを持つ。
    func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot

    /// 起動コマンドを実行し、running を実測するまで待つ。両方が揃わなければ throw する。
    func start(_ stack: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine]

    /// `identity`だけを停止し、notRunning を実測するまで待つ。
    /// `context`はコマンドの実行に使う設定。未登録スタックの停止にも対象側の呼び出し形式を使う。
    func stop(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine]

    /// 表示用の最新の実測値。起動・停止の待機中の再観測でも更新される。
    /// 読み出すだけでは外部コマンドを実行しない。まだ観測していなければ nil。
    var latestSnapshot: ManagedStackSnapshot? { get async }
}

/// 管理対象スタックの起動・停止の失敗。種類と ID を持ち、文言は種類の表示名から組み立てる。
public enum ManagedStackOperationError: Error, Equatable, Sendable, CustomStringConvertible {
    case commandFailed(
        action: String,
        identity: ManagedStackIdentity,
        status: ExitStatus,
        output: String
    )
    case commandUnavailable(action: String, identity: ManagedStackIdentity, reason: String)
    case stateNotConfirmed(
        action: String,
        identity: ManagedStackIdentity,
        expected: ManagedStackState,
        actual: ManagedStackState,
        detail: String?
    )

    public var description: String {
        switch self {
        case let .commandFailed(action, identity, status, output):
            let head = L10n.text("\(identity.type.displayName)「\(identity)」の\(action)コマンドが失敗しました（\(status.description)）。")
            return output.isEmpty ? head : head + L10n.text("\n直近の出力:\n") + output
        case let .commandUnavailable(action, identity, reason):
            return L10n.text("\(identity.type.displayName)「\(identity)」の\(action)コマンドを実行できません。\n\(reason)")
        case let .stateNotConfirmed(action, identity, expected, actual, detail):
            let head = L10n.text("\(identity.type.displayName)「\(identity)」の\(action)後に\(expected.label)を確認できませんでした（実測: \(actual.label)）。")
            return detail.map { head + "\n\($0)" } ?? head
        }
    }
}
