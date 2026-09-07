@testable import DevSwitcherApp
@testable import DevSwitcherCore
import Foundation
import Testing

@Suite("ツールバーの操作")
@MainActor
struct ToolbarActionsTests {
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

        #expect(!withoutPort.hasOpenableURLs)
        #expect(!withoutURL.hasOpenableURLs)
        #expect(withURL.hasOpenableURLs)
    }
}
