import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("起動確認")
struct StartupObservationTests {
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

    @Test("ポートを持たない種別でも起動確認できる")
    func everyKindObservesTheProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // MVP の判定材料はプロセスの生存だけ。ポートの有無で分岐しない。
        for kind in ServiceKind.allCases where kind != .docker {
            let withoutPort = service(kind: kind, ports: [], directory: directory)
            let spec = try StartupObservationPolicy.spec(for: withoutPort)
            #expect(spec.observationWindow == StartupObservationPolicy.defaultObservationWindow)

            let withPort = service(
                kind: kind,
                ports: [PortSpec(port: 3000, isPrimary: true)],
                directory: directory
            )
            #expect(try StartupObservationPolicy.spec(for: withPort) == spec)
        }
    }

    @Test("Docker は起動前に拒否する")
    func dockerKindIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = service(
            kind: .docker,
            ports: [PortSpec(port: 5432, isPrimary: true)],
            directory: directory
        )
        #expect(throws: StartupObservationError.self) {
            _ = try StartupObservationPolicy.spec(for: docker)
        }

        // ポートを外しても拒否は変わらない。理由はポートではなく lifecycle の未実装。
        let withoutPort = service(kind: .docker, ports: [], directory: directory)
        #expect(throws: StartupObservationError.self) {
            _ = try StartupObservationPolicy.spec(for: withoutPort)
        }
    }

    @Test("未対応機能を現行ロードマップに沿って案内する")
    func unsupportedFeaturesUseCurrentRoadmap() {
        let dockerMessage = StartupObservationError.unsupportedKind(
            service: "Database",
            kind: .docker
        ).description
        let managedCommandMessage = RuntimeError.stopCommandUnsupported(
            service: "Supabase"
        ).description

        #expect(dockerMessage.contains("Post-MVP"))
        #expect(managedCommandMessage.contains("Post-MVP"))
        #expect(!dockerMessage.contains("Milestone 3"))
        #expect(!managedCommandMessage.contains("Milestone 3"))
    }

    @Test("既定の観測窓は 3 秒")
    func defaultObservationWindowIsThreeSeconds() {
        #expect(StartupObservationPolicy.defaultObservationWindow == .seconds(3))
    }

    @Test("説明はプロセスの生存だけを指し、HTTP 応答を約束しない")
    func descriptionDoesNotPromiseHTTP() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = service(
            kind: .web,
            ports: [PortSpec(port: 3000, isPrimary: true)],
            directory: directory
        )
        let description = try StartupObservationPolicy.spec(for: web).description
        #expect(description.contains("プロセス"))
        #expect(!description.contains("http"))
        #expect(!description.contains("HTTP"))
        #expect(!description.contains("3000"))
    }
}
