@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("プロジェクト詳細")
@MainActor
struct ProjectDetailViewTests {
    @Test("URL付きポートがない場合は開くメニューを表示しない")
    func openMenuVisibilityDependsOnOpenURL() {
        let directory = URL(fileURLWithPath: "/tmp/project-detail-test")
        let withoutPort = makeWorkerProject(directory: directory)
        let withoutURL = makeWorkerProject(
            directory: directory,
            ports: [PortSpec(port: 3000, isPrimary: true)]
        )
        let withURL = makeWorkerProject(
            directory: directory,
            ports: [
                PortSpec(
                    port: 3000,
                    isPrimary: true,
                    openURL: "http://localhost:3000"
                ),
            ]
        )

        #expect(!ProjectDetailView(project: withoutPort).hasOpenMenuItems)
        #expect(!ProjectDetailView(project: withoutURL).hasOpenMenuItems)
        #expect(ProjectDetailView(project: withURL).hasOpenMenuItems)
    }
}
