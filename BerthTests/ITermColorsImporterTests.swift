import XCTest
@testable import Berth

final class ITermColorsImporterTests: XCTestCase {

    private func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
        ["Red Component": r, "Green Component": g, "Blue Component": b]
    }

    private func makeData(background: [String: Any], foreground: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var dict: [String: Any] = [
            "Background Color": background,
            "Foreground Color": foreground,
        ]
        for i in 0..<16 { dict["Ansi \(i) Color"] = color(0, 0, 0) }
        dict.merge(extra) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func testParsesColorsToHex() throws {
        let data = try makeData(
            background: color(0, 0, 0),
            foreground: color(1, 1, 1),
            extra: ["Cursor Color": color(1, 0, 0), "Ansi 4 Color": color(0, 0, 1)]
        )
        let theme = try ITermColorsImporter.theme(from: data, name: "My Theme.itermcolors")
        XCTAssertEqual(theme.background, "#000000")
        XCTAssertEqual(theme.foreground, "#FFFFFF")
        XCTAssertEqual(theme.cursor, "#FF0000")
        XCTAssertEqual(theme.accent, "#FF0000") // accent 取 cursor
        XCTAssertEqual(theme.ansi[4], "#0000FF")
        XCTAssertEqual(theme.ansi.count, 16)
    }

    func testNameAndSlug() throws {
        let data = try makeData(background: color(0, 0, 0), foreground: color(1, 1, 1))
        let theme = try ITermColorsImporter.theme(from: data, name: "Solarized Dark.itermcolors")
        XCTAssertEqual(theme.name, "Solarized Dark")
        XCTAssertEqual(theme.id, "iterm-solarized-dark")
    }

    func testDarkDetection() throws {
        let dark = try ITermColorsImporter.theme(
            from: makeData(background: color(0.05, 0.05, 0.05), foreground: color(1, 1, 1)),
            name: "d.itermcolors"
        )
        XCTAssertTrue(dark.isDark)
        let light = try ITermColorsImporter.theme(
            from: makeData(background: color(0.98, 0.98, 0.98), foreground: color(0, 0, 0)),
            name: "l.itermcolors"
        )
        XCTAssertFalse(light.isDark)
    }

    func testComponentRounding() throws {
        // 0.5 → 128, 0.333 → 85
        let data = try makeData(background: color(0.5, 0.333, 1.0), foreground: color(1, 1, 1))
        let theme = try ITermColorsImporter.theme(from: data, name: "x.itermcolors")
        XCTAssertEqual(theme.background, "#8055FF")
    }

    func testRejectsInvalidData() {
        XCTAssertThrowsError(try ITermColorsImporter.theme(from: Data("not a plist".utf8), name: "x"))
    }

    func testThemeRoundTripsCodable() throws {
        let data = try makeData(background: color(0, 0, 0), foreground: color(1, 1, 1))
        let theme = try ITermColorsImporter.theme(from: data, name: "rt.itermcolors")
        let encoded = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: encoded)
        XCTAssertEqual(decoded, theme)
    }
}
