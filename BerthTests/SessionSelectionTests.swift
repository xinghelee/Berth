import XCTest
@testable import Berth

@MainActor
final class SessionSelectionTests: XCTestCase {
    func testSelectingTerminalTabSynchronizesSidebarHostSelection() throws {
        let manager = SessionManager()
        let firstHostID = UUID()
        let secondHostID = UUID()

        manager.open(spec: spec(hostID: firstHostID, label: "first"), autoConnect: false)
        let firstTabID = try XCTUnwrap(manager.selectedTabID)

        manager.open(spec: spec(hostID: secondHostID, label: "second"), autoConnect: false)
        XCTAssertEqual(manager.selectedHostID, secondHostID)

        manager.selectTab(firstTabID)

        XCTAssertEqual(manager.selectedHostID, firstHostID)
    }

    func testFocusingSessionSynchronizesBothTabAndSidebarSelection() {
        let manager = SessionManager()
        let firstHostID = UUID()
        let firstSession = manager.open(
            spec: spec(hostID: firstHostID, label: "first"),
            autoConnect: false
        )
        manager.open(spec: spec(hostID: UUID(), label: "second"), autoConnect: false)

        manager.focusPane(firstSession.id)

        XCTAssertEqual(manager.selected?.id, firstSession.id)
        XCTAssertEqual(manager.selectedHostID, firstHostID)
    }

    func testClosingSelectedTabSynchronizesSidebarToNeighbor() throws {
        let manager = SessionManager()
        let firstHostID = UUID()

        manager.open(spec: spec(hostID: firstHostID, label: "first"), autoConnect: false)
        manager.open(spec: spec(hostID: UUID(), label: "second"), autoConnect: false)
        let selectedTab = try XCTUnwrap(manager.selectedTab)

        manager.closeTab(selectedTab)

        XCTAssertEqual(manager.selectedHostID, firstHostID)
    }

    func testSelectingLocalShellClearsSidebarHostSelection() {
        let manager = SessionManager()
        manager.open(spec: spec(hostID: UUID(), label: "remote"), autoConnect: false)

        manager.open(spec: .localShell(), autoConnect: false)

        XCTAssertNil(manager.selectedHostID)
    }

    private func spec(hostID: UUID, label: String) -> HostSpec {
        HostSpec(
            hostID: hostID,
            label: label,
            hostname: "\(label).example",
            port: 22,
            username: "dev",
            authMethod: .password,
            privateKeyPath: nil
        )
    }
}
