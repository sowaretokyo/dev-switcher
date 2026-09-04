import Foundation

/// 起動成功の判定条件。
///
/// MVP では HTTP を判定に使わない。設定ポートは表示と URL の補助情報であり、
/// そこへ GET しても、先に同じポートを取った別プロセスの応答を自分のものと誤認するだけになる。
/// 判定材料はプロセスの生存だけに絞る。
public struct StartupObservationSpec: Equatable, Sendable {
    /// 「起動直後に終了しなかった」と判断するまでの観測時間。
    public let observationWindow: Duration
    public let pollInterval: Duration

    public init(observationWindow: Duration, pollInterval: Duration) {
        self.observationWindow = observationWindow
        self.pollInterval = pollInterval
    }

    /// 何を見て起動成功と判断するのかを画面へ出すための説明。
    public var description: String {
        "プロセスが \(Int(observationWindow.seconds)) 秒間その場で終了せず、"
            + "観測終了時点でも管理下にあること"
    }
}

public enum StartupObservationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedKind(service: String, kind: ServiceKind)

    public var description: String {
        switch self {
        case let .unsupportedKind(service, kind):
            "サービス「\(service)」の種別「\(kind.displayName)」は MVP では起動できません。"
                + "Docker の managed lifecycle は Post-MVP で対応します。"
                + "起動コマンドの生存ではコンテナの稼働を判定できないため、起動を中止しました。"
        }
    }
}

/// 起動成功の判定方法。利用者へ設定を求めない。
public enum StartupObservationPolicy {
    /// 起動直後の観測時間。ここを過ぎても終了していなければ起動成功として扱う。
    public static let defaultObservationWindow: Duration = .seconds(3)
    public static let defaultPollInterval: Duration = .milliseconds(500)

    public static func spec(
        for service: ServiceDefinition,
        observationWindow: Duration = StartupObservationPolicy.defaultObservationWindow,
        pollInterval: Duration = StartupObservationPolicy.defaultPollInterval
    ) throws -> StartupObservationSpec {
        // Docker の managed lifecycle は Post-MVP。`docker compose up` はコマンド自身が
        // 終了してもコンテナが残るため、プロセスの生存では起動を判定できない。
        // 既定へ倒さず、起動前に拒否する。
        if service.kind == .docker {
            throw StartupObservationError.unsupportedKind(
                service: service.name,
                kind: service.kind
            )
        }
        return StartupObservationSpec(
            observationWindow: observationWindow,
            pollInterval: pollInterval
        )
    }
}
