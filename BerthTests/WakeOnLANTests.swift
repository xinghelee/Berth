import XCTest
@testable import Berth

final class WakeOnLANTests: XCTestCase {

    func testParseMACVariants() {
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33]
        XCTAssertEqual(WakeOnLAN.parseMAC("AA:BB:CC:11:22:33"), expected)
        XCTAssertEqual(WakeOnLAN.parseMAC("aa-bb-cc-11-22-33"), expected)
        XCTAssertEqual(WakeOnLAN.parseMAC("aabbcc112233"), expected)
        XCTAssertEqual(WakeOnLAN.parseMAC("AA BB CC 11 22 33"), expected)
    }

    func testParseMACRejectsBadInput() {
        XCTAssertNil(WakeOnLAN.parseMAC("AA:BB:CC:11:22"))       // 5 组
        XCTAssertNil(WakeOnLAN.parseMAC("AA:BB:CC:11:22:33:44")) // 7 组
        XCTAssertNil(WakeOnLAN.parseMAC("GG:BB:CC:11:22:33"))    // 非十六进制
        XCTAssertNil(WakeOnLAN.parseMAC(""))
    }

    func testMagicPacketFormat() {
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33]
        let packet = WakeOnLAN.magicPacket(for: mac)
        XCTAssertEqual(packet.count, 102)                       // 6 + 16*6
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        // 之后 16 段都等于 MAC
        for i in 0..<16 {
            let start = 6 + i * 6
            XCTAssertEqual(Array(packet[start..<start + 6]), mac)
        }
    }

    func testSubnetBroadcast() {
        XCTAssertEqual(WakeOnLAN.subnetBroadcast(for: "192.168.1.200"), "192.168.1.255")
        XCTAssertNil(WakeOnLAN.subnetBroadcast(for: "example.com"))
        XCTAssertNil(WakeOnLAN.subnetBroadcast(for: "10.0.0"))
    }
}
