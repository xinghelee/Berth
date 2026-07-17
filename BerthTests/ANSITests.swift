import XCTest
@testable import Berth

final class ANSITests: XCTestCase {

    func testStripsColorCodes() {
        XCTAssertEqual(ANSI.strip("\u{1B}[31mred\u{1B}[0m"), "red")
        XCTAssertEqual(ANSI.strip("\u{1B}[1;32mBERTH_L1\u{1B}[0m: ok"), "BERTH_L1: ok")
    }

    func testKeepsNewlinesAndTabs() {
        XCTAssertEqual(ANSI.strip("a\tb\nc"), "a\tb\nc")
    }

    func testStripsOSCSequences() {
        // OSC 0 ; title BEL
        XCTAssertEqual(ANSI.strip("\u{1B}]0;window title\u{07}hello"), "hello")
    }

    func testStripsBareControlChars() {
        XCTAssertEqual(ANSI.strip("ab\u{08}c"), "abc") // backspace removed, keep visible
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(ANSI.strip("just plain text 123"), "just plain text 123")
    }
}
