import Foundation

/// ヘルスチェック1回分の結果。「到達できない」と「5xx を返した」を混ぜない。
/// 起動直後の接続拒否は待てば解消するが、5xx は待っても直らないことがあるため、
/// 呼び出し側が理由を文章にできるよう区別して返す。
public enum HealthProbeResult: Equatable, Sendable {
    case healthy(statusCode: Int)
    case serverError(statusCode: Int)
    case unreachable(reason: String)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case let .healthy(code): "HTTP \(code)"
        case let .serverError(code): "HTTP \(code) が返りました"
        case let .unreachable(reason): reason
        }
    }
}

/// HTTP ヘルスチェックの実行。テストでネットワークへ出ないよう差し替え可能にする。
public struct HealthProbe: Sendable {
    public typealias HTTPRequest = @Sendable (URL) async -> HealthProbeResult

    private let request: HTTPRequest

    public init(request: @escaping HTTPRequest = HealthProbe.urlSessionRequest) {
        self.request = request
    }

    public func probe(port: Int, path: String) async -> HealthProbeResult {
        guard let url = HealthProbe.url(port: port, path: path) else {
            return .unreachable(reason: "ヘルスチェック URL を組み立てられません（ポート \(port) / パス \(path)）。")
        }
        return await request(url)
    }

    /// ループバック固定。LAN 経由の到達性は Expo の QR で別途扱う話であり、
    /// ローカルサービスの利用可能性判定には使わない。
    public static func url(port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    /// 既定の実装。1回あたりの待ちは短くし、全体のタイムアウトは呼び出し側のループで管理する。
    public static let urlSessionRequest: HTTPRequest = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        // 開発サーバーは自己署名や独自プロキシ設定と干渉しやすいので、系統の設定を持ち込まない。
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(reason: "HTTP 応答として解釈できませんでした。")
            }
            // 「タイムアウトと 5xx 以外」を通過とする（DESIGN.md 5章）。
            // 404 でもプロセスは応答しているので、利用可能とみなす。
            return http.statusCode >= 500
                ? .serverError(statusCode: http.statusCode)
                : .healthy(statusCode: http.statusCode)
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }
}
