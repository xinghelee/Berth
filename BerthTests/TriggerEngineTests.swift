import XCTest
@testable import Berth

/// TriggerEngine 的 ANSI 剥离用 @MainActor 内部实现;这里测公开可达的正则与剥离行为的等价逻辑。
final class TriggerEngineTests: XCTestCase {

    /// 与引擎同款的 ANSI 剥离正则,验证颜色码被清掉后能匹配纯文本
    func testAnsiStripAllowsMatch() throws {
        let ansi = try NSRegularExpression(
            pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}]"
        )
        let colored = "\u{1B}[31mERROR\u{1B}[0m: disk full"
        let range = NSRange(colored.startIndex..., in: colored)
        let stripped = ansi.stringByReplacingMatches(in: colored, options: [], range: range, withTemplate: "")
        XCTAssertEqual(stripped, "ERROR: disk full")

        let rule = try NSRegularExpression(pattern: "ERROR|panic", options: [.caseInsensitive])
        let sRange = NSRange(stripped.startIndex..., in: stripped)
        XCTAssertNotNil(rule.firstMatch(in: stripped, options: [], range: sRange))
    }

    func testCaseInsensitiveMatch() throws {
        let rule = try NSRegularExpression(pattern: "failed", options: [.caseInsensitive])
        let line = "Job FAILED after 3 retries"
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(rule.firstMatch(in: line, options: [], range: range))
    }

    func testNonMatchingLine() throws {
        let rule = try NSRegularExpression(pattern: "ERROR", options: [.caseInsensitive])
        let line = "everything is fine"
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNil(rule.firstMatch(in: line, options: [], range: range))
    }
}
