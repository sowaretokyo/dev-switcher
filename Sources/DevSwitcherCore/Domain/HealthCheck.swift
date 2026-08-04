import Foundation

/// 利用可能性の判定方法。listen 開始だけでは稼働中にしないため、TCP 到達性は判定に使わない。
public enum HealthCheckMethod: Equatable, Sendable {
    /// 指定ポートへの HTTP GET。タイムアウトと 5xx 以外の応答を通過とする。
    case httpGet(port: Int, path: String)
    /// ポートも HTTP エンドポイントも持たないサービス。
    /// 短い初期観測期間に異常終了しなかったことを通過とする。
    case processAlive
}

public struct HealthCheckSpec: Equatable, Sendable {
    public let method: HealthCheckMethod
    /// 全体の待ち時間。超えたら黙って待ち続けず、起動失敗として理由を返す。
    public let timeout: Duration
    /// `processAlive` で「異常終了しなかった」と判断するまでの観測時間。
    public let observationWindow: Duration
    public let pollInterval: Duration

    public init(
        method: HealthCheckMethod,
        timeout: Duration,
        observationWindow: Duration,
        pollInterval: Duration
    ) {
        self.method = method
        self.timeout = timeout
        self.observationWindow = observationWindow
        self.pollInterval = pollInterval
    }

    /// 何を待っているのかを画面へ出すための説明。
    public var description: String {
        switch method {
        case let .httpGet(port, path):
            "http://127.0.0.1:\(port)\(path) への GET"
        case .processAlive:
            "プロセスが \(Int(observationWindow.seconds)) 秒間その場で終了しないこと"
        }
    }
}

public enum HealthCheckPolicyError: Error, Equatable, Sendable, CustomStringConvertible {
    case portRequired(service: String, kind: ServiceKind)
    case unsupportedKind(service: String, kind: ServiceKind)

    public var description: String {
        switch self {
        case let .portRequired(service, kind):
            "サービス「\(service)」の種別「\(kind.displayName)」はヘルスチェックにポートが必要です。ポートを登録するか、種別を「\(ServiceKind.worker.displayName)」にしてください。"
        case let .unsupportedKind(service, kind):
            "サービス「\(service)」の種別「\(kind.displayName)」のヘルスチェックは未実装です（Milestone 3 で managed command とともに実装）。TCP 到達だけで稼働中と扱わないため、起動を中止しました。"
        }
    }
}

/// サービス種別ごとの既定ヘルスチェック（DESIGN.md 5章・決定 d）。利用者へ設定を求めない。
public enum HealthCheckPolicy {
    /// DESIGN.md の既定値。超えたら「応答待ち」で放置せず失敗として扱う。
    public static let defaultTimeout: Duration = .seconds(90)
    /// ポートを持たないサービスの初期観測期間。
    public static let defaultObservationWindow: Duration = .seconds(3)
    public static let defaultPollInterval: Duration = .milliseconds(500)

    public static func spec(
        for service: ServiceDefinition,
        timeout: Duration = HealthCheckPolicy.defaultTimeout,
        observationWindow: Duration = HealthCheckPolicy.defaultObservationWindow,
        pollInterval: Duration = HealthCheckPolicy.defaultPollInterval
    ) throws -> HealthCheckSpec {
        let method = try method(for: service)
        return HealthCheckSpec(
            method: method,
            timeout: timeout,
            observationWindow: observationWindow,
            pollInterval: pollInterval
        )
    }

    private static func method(for service: ServiceDefinition) throws -> HealthCheckMethod {
        switch service.kind {
        case .web:
            .httpGet(port: try healthPort(of: service), path: "/")
        case .supabase:
            // Supabase は API/DB/Studio など複数ポートを持つ。判定は API ポートで行う。
            .httpGet(port: try apiPort(of: service), path: "/rest/v1/")
        case .expo:
            .httpGet(port: try healthPort(of: service), path: "/status")
        case .inngest:
            .httpGet(port: try healthPort(of: service), path: "/health")
        case .worker:
            // ポートを listen していても HTTP を話すとは限らないため、生存だけを見る。
            .processAlive
        case .other:
            if let port = service.primaryPort {
                .httpGet(port: port.port, path: "/")
            } else {
                .processAlive
            }
        case .docker:
            // `docker compose ps` の healthy 判定は Milestone 3。
            // TCP 到達だけで緑にすると「緑なのに使えない」を作るため、既定へ倒さない。
            throw HealthCheckPolicyError.unsupportedKind(
                service: service.name,
                kind: service.kind
            )
        }
    }

    /// 代表ポート。持たない種別は設定不整合なので補完せず失敗させる。
    private static func healthPort(of service: ServiceDefinition) throws -> Int {
        guard let port = service.primaryPort else {
            throw HealthCheckPolicyError.portRequired(
                service: service.name,
                kind: service.kind
            )
        }
        return port.port
    }

    /// Supabase の API ポート。ラベル "API" を優先し、無ければ代表ポートを使う。
    private static func apiPort(of service: ServiceDefinition) throws -> Int {
        if let labeled = service.ports.first(where: {
            $0.label?.caseInsensitiveCompare("API") == .orderedSame
        }) {
            return labeled.port
        }
        return try healthPort(of: service)
    }
}
