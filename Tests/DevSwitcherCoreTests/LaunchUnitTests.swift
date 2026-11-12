import Foundation
import Testing
@testable import DevSwitcherCore

/// 起動単位（docs/ARCHITECTURE.md 4.3）が、Phase A の現行の起動順・停止順・起動対象と同じ並びになること。
@Suite("起動単位")
struct LaunchUnitTests {
    private let directory = URL(fileURLWithPath: "/tmp/devswitcher-launch-unit-tests", isDirectory: true)

    private func makeServices() -> (web: LaunchUnit, supabase: LaunchUnit, worker: LaunchUnit) {
        (
            web: makeService(name: "Web", kind: .web, workingDirectory: directory),
            supabase: makeSupabaseService(name: "DB", workingDirectory: directory),
            worker: makeService(name: "Worker", kind: .worker, ports: [], workingDirectory: directory)
        )
    }

    @Test("launchUnitsはstartupOrderと同じ順で、Supabaseだけをスタックへ変換する")
    func launchUnitsFollowStartupOrder() throws {
        let services = makeServices()
        let project = makeProject(
            directory: directory,
            services: [services.web, services.supabase, services.worker]
        )

        let definition = try #require(services.supabase.managedStackDefinition)
        #expect(project.launchUnits == [
            .stack(definition, workingDirectory: services.supabase.start.workingDirectory),
            .process(services.web),
            .process(services.worker),
        ])
        #expect(project.launchUnits.dropFirst().map(\.id) == project.startupOrder.map(\.id))
        #expect(project.launchUnits.dropFirst().map(\.name) == project.startupOrder.map(\.name))
    }

    @Test("enabledLaunchUnitsはenabledStartupOrderと同じ対象・同じ順になる")
    func enabledLaunchUnitsFollowEnabledStartupOrder() {
        let services = makeServices()
        var disabledByDefault = makeService(name: "Docs", kind: .other, workingDirectory: directory)
        disabledByDefault.enabledByDefault = false
        let project = makeProject(
            directory: directory,
            services: [services.web, services.supabase, disabledByDefault, services.worker],
            enabledNow: [services.web.id: false]
        )

        #expect(project.enabledLaunchUnits.filter { $0.processDefinition != nil }.map(\.id) == project.enabledStartupOrder.map(\.id))
        #expect(project.enabledLaunchUnits.map(\.id) == [services.supabase.id, services.worker.id])
    }

    @Test("今回起動しないSupabaseはenabledLaunchUnitsに含めない")
    func disabledStackIsExcluded() {
        let services = makeServices()
        let project = makeProject(
            directory: directory,
            services: [services.web, services.supabase, services.worker],
            enabledNow: [services.supabase.id: false]
        )

        #expect(project.enabledLaunchUnits.filter { $0.processDefinition != nil }.map(\.id) == project.enabledStartupOrder.map(\.id))
        #expect(project.enabledLaunchUnits.map(\.id) == [services.web.id, services.worker.id])
        #expect(project.enabledLaunchUnits.allSatisfy {
            if case .process = $0 { true } else { false }
        })
    }

    @Test("shutdownUnitsは既定で起動順の逆になる")
    func shutdownUnitsDefaultToReversedStartupOrder() {
        let services = makeServices()
        let project = makeProject(
            directory: directory,
            services: [services.web, services.supabase, services.worker]
        )

        #expect(project.shutdownUnits.dropLast().map(\.id) == project.shutdownOrder.map(\.id))
        #expect(project.shutdownUnits.map(\.id) == [services.worker.id, services.web.id, services.supabase.id])
    }

    @Test("shutdownUnitsはstopOrderの指定順に従う")
    func shutdownUnitsFollowStopOrder() {
        let services = makeServices()
        let stopOrder = [services.supabase.id, services.web.id, services.worker.id]
        let project = makeProject(
            directory: directory,
            services: [services.web, services.supabase, services.worker],
            stopOrder: stopOrder
        )

        #expect(project.shutdownUnits.dropLast().map(\.id) == project.shutdownOrder.map(\.id))
        #expect(project.shutdownUnits.map(\.id) == [services.web.id, services.worker.id, services.supabase.id])
    }

    @Test("supabase以外の種類は、すべて通常プロセスの起動単位になる")
    func nonStackKindsBecomeProcesses() {
        for kind in ServiceKind.allCases where kind != .supabase {
            let service = makeService(name: kind.displayName, kind: kind, workingDirectory: directory)
            #expect(LaunchUnit(service) == .process(service))
        }
    }
}
