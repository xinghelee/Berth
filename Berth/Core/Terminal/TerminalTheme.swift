import AppKit
import Observation
import SwiftTerm

/// 终端配色主题。内置 4 套,深色为默认;iTerm2 导入在二期。
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String   // hex
    let foreground: String
    let cursor: String
    let selection: String
    /// 16 色 ANSI(黑红绿黄蓝品青白 + 亮色)
    let ansi: [String]

    var backgroundNSColor: NSColor { NSColor(hex: background) }
    var foregroundNSColor: NSColor { NSColor(hex: foreground) }
}

extension TerminalTheme {

    /// 默认:精调深色(One Dark 气质)
    static let berthDark = TerminalTheme(
        id: "berth-dark",
        name: "Berth 深色",
        isDark: true,
        background: "#1B1E25",
        foreground: "#EBEEF2",
        cursor: "#56B6C2",
        selection: "#3E4451",
        ansi: [
            "#1B1E25", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
            "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
        ]
    )

    static let catppuccinMacchiato = TerminalTheme(
        id: "catppuccin-macchiato",
        name: "Catppuccin Macchiato",
        isDark: true,
        background: "#24273A",
        foreground: "#CAD3F5",
        cursor: "#F4DBD6",
        selection: "#454A5F",
        ansi: [
            "#494D64", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#B8C0E0",
            "#5B6078", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB",
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        isDark: true,
        background: "#002B36",
        foreground: "#839496",
        cursor: "#93A1A1",
        selection: "#073642",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ]
    )

    static let oneLight = TerminalTheme(
        id: "one-light",
        name: "One Light(浅色)",
        isDark: false,
        background: "#FAFAFA",
        foreground: "#383A42",
        cursor: "#526EFF",
        selection: "#E5E5E6",
        ansi: [
            "#383A42", "#E45649", "#50A14F", "#C18401", "#4078F2", "#A626A4", "#0184BC", "#A0A1A7",
            "#696C77", "#E45649", "#50A14F", "#C18401", "#4078F2", "#A626A4", "#0184BC", "#FFFFFF",
        ]
    )

    static let builtIn: [TerminalTheme] = [.berthDark, .catppuccinMacchiato, .solarizedDark, .oneLight]
}

/// 主题状态:持有当前主题,负责应用到 TerminalView(含 live 切换所有活跃会话)
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var current: TerminalTheme

    init() {
        let savedID = UserDefaults.standard.string(forKey: SettingsKeys.terminalTheme)
        current = TerminalTheme.builtIn.first { $0.id == savedID } ?? .berthDark
    }

    func select(id: String) {
        guard let theme = TerminalTheme.builtIn.first(where: { $0.id == id }) else { return }
        current = theme
        UserDefaults.standard.set(theme.id, forKey: SettingsKeys.terminalTheme)
        for session in SessionManager.shared.sessions {
            apply(to: session.terminalView)
        }
    }

    func apply(to view: SwiftTerm.TerminalView) {
        view.nativeBackgroundColor = current.backgroundNSColor
        view.nativeForegroundColor = current.foregroundNSColor
        view.caretColor = NSColor(hex: current.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: current.selection)
        view.installColors(current.ansi.map { SwiftTerm.Color(hex: $0) })
    }
}

// MARK: - hex 解析

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = hexComponents(hex)
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension SwiftTerm.Color {
    convenience init(hex: String) {
        let (r, g, b) = hexComponents(hex)
        self.init(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
}

private func hexComponents(_ hex: String) -> (Int, Int, Int) {
    var text = hex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text = String(text.dropFirst()) }
    guard text.count == 6, let value = Int(text, radix: 16) else { return (0, 0, 0) }
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
}
