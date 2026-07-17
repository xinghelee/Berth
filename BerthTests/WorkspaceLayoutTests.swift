import XCTest
@testable import Berth

final class WorkspaceLayoutTests: XCTestCase {

    func testRoundTripSingleTab() {
        let host = UUID()
        let layout = WorkspaceLayout(tabs: [.leaf(hostID: host)])
        let restored = WorkspaceLayout.decode(layout.encodedJSON())
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored?.hostCount, 1)
        XCTAssertEqual(restored?.tabs.count, 1)
    }

    func testRoundTripNestedSplits() {
        let a = UUID(), b = UUID(), c = UUID()
        // 一个标签:a 与(b 上下分屏 c)左右分屏
        let layout = WorkspaceLayout(tabs: [
            .split(axis: "h", first: .leaf(hostID: a),
                   second: .split(axis: "v", first: .leaf(hostID: b), second: .leaf(hostID: c)))
        ])
        let restored = WorkspaceLayout.decode(layout.encodedJSON())
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored?.hostCount, 3)
    }

    func testHostCountAcrossTabs() {
        let layout = WorkspaceLayout(tabs: [
            .leaf(hostID: UUID()),
            .split(axis: "h", first: .leaf(hostID: UUID()), second: .leaf(hostID: UUID())),
        ])
        XCTAssertEqual(layout.tabs.count, 2)
        XCTAssertEqual(layout.hostCount, 3)
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(WorkspaceLayout.decode("not json"))
        XCTAssertNil(WorkspaceLayout.decode(""))
    }
}
