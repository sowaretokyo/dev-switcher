import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("切替状態")
struct SwitchStateTests {
    @Test("終了操作は Dev Switcher の管理下にあるプロセスだけに提供する")
    func terminationIsOfferedOnlyForOwnedProcesses() {
        let owned = PortOwnership.ownedByUs(
            serviceID: UUID(),
            serviceName: "Web"
        )

        #expect(owned.canOfferTermination)
        #expect(!PortOwnership.external.canOfferTermination)
        #expect(!PortOwnership.systemOwned.canOfferTermination)
    }
}
