import UniformTypeIdentifiers
import XCTest
@testable import Berth

/// issue #46:未指定编辑器时,哪些远端文件名可以交给 macOS 默认应用、默认应用本身要满足什么
final class RemoteEditOpenPolicyTests: XCTestCase {

    // MARK: 类型门

    func testPlainTextLikeTypesAreEligible() {
        for ext in ["yaml", "yml", "json", "md", "txt", "csv", "css", "xml", "swift"] {
            let type = RemoteEditOpenPolicy.textType(forFilenameExtension: ext)
            XCTAssertNotNil(type, ext)
            XCTAssertTrue(type?.conforms(to: .text) ?? false, ext)
        }
        XCTAssertEqual(RemoteEditOpenPolicy.textType(forFilenameExtension: "yaml"), .yaml)
        XCTAssertEqual(RemoteEditOpenPolicy.textType(forFilenameExtension: "json"), .json)
    }

    func testScriptsAreRejectedEvenThoughTheyAreText() {
        // Terminal / Python Launcher 会直接执行这些,而不是编辑
        for ext in ["sh", "command", "tool", "py", "rb", "pl", "php", "js", "applescript", "scpt", "mk"] {
            XCTAssertNil(RemoteEditOpenPolicy.textType(forFilenameExtension: ext), ext)
        }
    }

    func testWebAndImageTypesAreRejected() {
        for ext in ["html", "htm", "xhtml", "svg", "png"] {
            XCTAssertNil(RemoteEditOpenPolicy.textType(forFilenameExtension: ext), ext)
        }
    }

    func testNonTextAndUndeclaredTypesAreRejected() {
        // .terminal / .webloc / .url 是 58bb856 加固时点名的「会被执行」类型;.dmg/.pkg/.app 不是文本;
        // 没人声明的扩展名是 dyn.* 动态类型,也不放行
        for ext in ["terminal", "webloc", "inetloc", "url", "dmg", "pkg", "app", "jar", "", " ", "no-such-ext-berth"] {
            XCTAssertNil(RemoteEditOpenPolicy.textType(forFilenameExtension: ext), "'\(ext)'")
        }
    }

    // MARK: 程序门

    private let editor = URL(fileURLWithPath: "/Applications/Sublime Text.app")
    private let plainTextApps = [
        URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
        URL(fileURLWithPath: "/Applications/Sublime Text.app/"),
    ]

    func testDefaultHandlerMustDeclarePlainTextSupport() {
        XCTAssertTrue(RemoteEditOpenPolicy.isTrustedEditor(editor, plainTextApps: plainTextApps, urlSchemes: ["subl"]))
        // ProfileHelper / Terminal / Surge 这类导入执行型程序不声明能开纯文本
        let profileHelper = URL(fileURLWithPath: "/System/Library/CoreServices/ProfileHelper.app")
        XCTAssertFalse(RemoteEditOpenPolicy.isTrustedEditor(profileHelper, plainTextApps: plainTextApps, urlSchemes: []))
        XCTAssertFalse(RemoteEditOpenPolicy.isTrustedEditor(editor, plainTextApps: [], urlSchemes: []))
    }

    func testBrowsersAreRejectedEvenIfTheyOpenPlainText() {
        // Safari/Chrome 都声明能开纯文本,靠注册了 http/https scheme 识别
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let apps = plainTextApps + [safari]
        XCTAssertFalse(RemoteEditOpenPolicy.isTrustedEditor(safari, plainTextApps: apps, urlSchemes: ["http", "https", "file"]))
        XCTAssertFalse(RemoteEditOpenPolicy.isTrustedEditor(safari, plainTextApps: apps, urlSchemes: ["HTTPS"]))
        XCTAssertTrue(RemoteEditOpenPolicy.isTrustedEditor(safari, plainTextApps: apps, urlSchemes: ["file"]))
    }

    func testAppPathComparisonIgnoresTrailingSlash() {
        let withSlash = URL(fileURLWithPath: "/Applications/Sublime Text.app/")
        XCTAssertTrue(RemoteEditOpenPolicy.isTrustedEditor(withSlash, plainTextApps: [editor], urlSchemes: []))
    }
}
