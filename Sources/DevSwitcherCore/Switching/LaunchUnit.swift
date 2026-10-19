import Foundation

/// 起動フェーズで扱う 1 単位。プロセスと管理対象スタックを 1 つの列にする（docs/ARCHITECTURE.md 4.3）。
///
/// Phase A ではデータモデルを変えないため、`services`の各要素をアダプタ
/// （`ServiceDefinition.managedStackDefinition`）で変換して作る。スタックの ID は元のサービスの ID と同じ。
enum LaunchUnit: Equatable, Sendable {
    /// `workingDirectory`は設定の検証と ID の解決に使う基準ディレクトリ。
    case stack(ManagedStackDefinition, workingDirectory: URL)
    case process(ServiceDefinition)

    /// アダプタで管理対象スタックになるサービスは`.stack`、それ以外は`.process`。
    init(_ service: ServiceDefinition) {
        if let definition = service.managedStackDefinition {
            self = .stack(definition, workingDirectory: service.start.workingDirectory)
        } else {
            self = .process(service)
        }
    }

    var id: UUID {
        switch self {
        case let .stack(definition, _): definition.id
        case let .process(service): service.id
        }
    }

    var name: String {
        switch self {
        case let .stack(definition, _): definition.name
        case let .process(service): service.name
        }
    }
}

extension ProjectDefinition {
    /// 起動順。Phase A では`startupOrder`（配列順）をそのまま変換する。
    /// Phase C 以降はスタック（登録順）→ プロセス（起動順）になる。
    var launchUnits: [LaunchUnit] {
        startupOrder.map(LaunchUnit.init)
    }

    /// 今回起動する単位を起動順で返す。起動対象の判定は`enabledStartupOrder`と同じ。
    var enabledLaunchUnits: [LaunchUnit] {
        enabledStartupOrder.map(LaunchUnit.init)
    }

    /// 停止順。Phase A では`shutdownOrder`（`stopOrder`、無ければ起動順の逆）をそのまま変換する。
    var shutdownUnits: [LaunchUnit] {
        shutdownOrder.map(LaunchUnit.init)
    }
}
