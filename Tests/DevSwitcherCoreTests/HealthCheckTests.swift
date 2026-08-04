import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("ヘルスチェック")
struct HealthCheckTests {
    private func service(
        kind: ServiceKind,
        ports: [PortSpec],
        directory: URL
    ) -> ServiceDefinition {
        makeService(
            name: kind.displayName,
            kind: kind,
            ports: ports,
            executable: "/bin/echo",
            arguments: ["x"],
            workingDirectory: directory
        )
    }

    @Test("種別ごとの既定を使い、利用者へ設定を求めない")
    func usesBuiltInDefaultsPerKind() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = service(kind: .web, ports: [PortSpec(port: 3000, isPrimary: true)], directory: directory)
        #expect(try HealthCheckPolicy.spec(for: web).method == .httpGet(port: 3000, path: "/"))

        let expo = service(kind: .expo, ports: [PortSpec(port: 8081, isPrimary: true)], directory: directory)
        #expect(try HealthCheckPolicy.spec(for: expo).method == .httpGet(port: 8081, path: "/status"))

        let inngest = service(kind: .inngest, ports: [PortSpec(port: 8288, isPrimary: true)], directory: directory)
        #expect(try HealthCheckPolicy.spec(for: inngest).method == .httpGet(port: 8288, path: "/health"))
    }

    @Test("Supabase は代表ポートではなく API ポートで判定する")
    func supabaseUsesApiPort() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supabase = service(
            kind: .supabase,
            ports: [
                PortSpec(label: "Studio", port: 54_323, isPrimary: true),
                PortSpec(label: "API", port: 54_321, isPrimary: false),
                PortSpec(label: "DB", port: 54_322, isPrimary: false),
            ],
            directory: directory
        )
        #expect(
            try HealthCheckPolicy.spec(for: supabase).method
                == .httpGet(port: 54_321, path: "/rest/v1/")
        )
    }

    @Test("ポートを持たない worker はプロセスの生存で判定する")
    func workerUsesProcessObservation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let worker = service(kind: .worker, ports: [], directory: directory)
        #expect(try HealthCheckPolicy.spec(for: worker).method == .processAlive)

        let other = service(kind: .other, ports: [], directory: directory)
        #expect(try HealthCheckPolicy.spec(for: other).method == .processAlive)
    }

    @Test("HTTP で判定する種別にポートが無ければ、既定へ倒さず失敗させる")
    func httpKindWithoutPortFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = service(kind: .web, ports: [], directory: directory)
        #expect(throws: HealthCheckPolicyError.self) {
            _ = try HealthCheckPolicy.spec(for: web)
        }
    }

    @Test("Docker のヘルス判定は未実装として拒否する")
    func dockerKindIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = service(kind: .docker, ports: [PortSpec(port: 5432, isPrimary: true)], directory: directory)
        #expect(throws: HealthCheckPolicyError.self) {
            _ = try HealthCheckPolicy.spec(for: docker)
        }
    }

    @Test("既定のタイムアウトは 90 秒")
    func defaultTimeoutIsNinetySeconds() {
        #expect(HealthCheckPolicy.defaultTimeout == .seconds(90))
    }

    @Test("応答するサーバーだけを通過とする")
    func passesOnlyWhenServerResponds() async throws {
        let server = try LocalTCPServer(behavior: .http(status: 200))
        defer { server.stop() }

        let probe = HealthProbe()
        let result = await probe.probe(port: server.port, path: "/")
        #expect(result.isHealthy)
    }

    @Test("5xx は通過にしない")
    func serverErrorIsNotHealthy() async throws {
        let server = try LocalTCPServer(behavior: .http(status: 503))
        defer { server.stop() }

        let probe = HealthProbe()
        let result = await probe.probe(port: server.port, path: "/")
        #expect(!result.isHealthy)
        #expect(result == .serverError(statusCode: 503))
    }

    @Test("404 でもプロセスは応答しているので通過とする")
    func notFoundIsHealthy() async throws {
        let server = try LocalTCPServer(behavior: .http(status: 404))
        defer { server.stop() }

        let probe = HealthProbe()
        let result = await probe.probe(port: server.port, path: "/")
        #expect(result.isHealthy)
    }

    @Test("listen していても応答しなければ通過にしない")
    func listeningWithoutResponseIsNotHealthy() async throws {
        // TCP としては接続できるが、HTTP としては応答しない。
        // TCP 到達性を利用可能性と混同しないことの確認。
        let server = try LocalTCPServer(behavior: .silent)
        defer { server.stop() }

        let probe = HealthProbe()
        let result = await probe.probe(port: server.port, path: "/")
        #expect(!result.isHealthy)
    }

    @Test("ループバックへ問い合わせる")
    func probesLoopbackOnly() {
        let url = HealthProbe.url(port: 3000, path: "/status")
        #expect(url?.absoluteString == "http://127.0.0.1:3000/status")
    }
}
