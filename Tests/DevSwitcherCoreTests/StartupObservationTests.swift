import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("起動確認と終了イベント")
struct StartupConfirmationEventTests {
    @Test("起動確認後の終了には確認済みの事実を付ける")
    func confirmedStartupIsAttachedToExitEvent() async {
        let observation = ServiceObservation()

        #expect(await observation.confirmStartup())
        let event = await observation.record(
            .exited(
                status: .exited(code: 7),
                requestedByUser: false,
                startupConfirmed: false
            )
        )

        guard case let .exited(_, _, startupConfirmed) = event else {
            Issue.record("終了イベントではありません")
            return
        }
        #expect(startupConfirmed)
    }

    @Test("起動確認前の終了は起動失敗として区別する")
    func exitBeforeConfirmationIsNotConfirmed() async {
        let observation = ServiceObservation()

        let event = await observation.record(
            .exited(
                status: .exited(code: 7),
                requestedByUser: false,
                startupConfirmed: false
            )
        )

        guard case let .exited(_, _, startupConfirmed) = event else {
            Issue.record("終了イベントではありません")
            return
        }
        #expect(startupConfirmed == false)
        #expect(await observation.confirmStartup() == false)
    }
}

@Suite("起動確認")
struct StartupObservationTests {
    private func service(
        kind: ServiceKind,
        ports: [PortSpec],
        directory: URL
    ) -> LaunchUnit {
        .process(DevSwitcherCore.ServiceDefinition(name: kind.displayName, tag: kind.rawValue, ports: ports,
            start: CommandSpec(executable: "/bin/echo", arguments: ["x"], workingDirectory: directory), enabledByDefault: true, failurePolicy: .block))
    }

    @Test("ポートを持たない種別でも起動確認できる")
    func everyKindObservesTheProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // MVP の判定材料はプロセスの生存だけ。ポートの有無で分岐しない。
        for kind in ServiceKind.allCases {
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

    @Test("Docker タグの通常プロセスにも生存による初期観測を適用する")
    func dockerTagUsesProcessObservation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let docker = service(kind: .docker, ports: [], directory: directory)
        #expect(try StartupObservationPolicy.spec(for: docker).observationWindow == .seconds(3))
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
