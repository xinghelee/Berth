import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// 配色主题:既驱动终端 ANSI 配色,也驱动整个窗口的界面(侧栏/列表/标签)配色,
/// 让全局观感统一。内置若干套,深色为默认;iTerm2 导入在二期。
struct TerminalTheme: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String   // hex
    let foreground: String
    let cursor: String
    let selection: String
    /// 强调色(选中态、按钮、光标条),界面与终端共用
    let accent: String
    /// 16 色 ANSI(黑红绿黄蓝品青白 + 亮色)
    let ansi: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, isDark, background, foreground, cursor, selection, accent, ansi
    }

    // MARK: 终端色
    var backgroundNSColor: NSColor { NSColor(hex: background) }
    var foregroundNSColor: NSColor { NSColor(hex: foreground) }

    // MARK: 界面色(由背景/强调色派生,保证与终端同源)
    var accentColor: SwiftUI.Color { SwiftUI.Color(nsColor: NSColor(hex: accent)) }
    /// 窗口/终端区底色
    var chromeBackground: SwiftUI.Color { SwiftUI.Color(nsColor: backgroundNSColor) }
    /// 侧栏底色:深色比背景更深一档、浅色略压灰,拉开与终端区的层次
    var sidebarBackground: SwiftUI.Color { SwiftUI.Color(nsColor: backgroundNSColor.mixed(with: .black, ratio: isDark ? 0.35 : 0.05)) }
    /// 主机列表/面板底色:比背景略亮
    var panelBackground: SwiftUI.Color { SwiftUI.Color(nsColor: backgroundNSColor.mixed(with: isDark ? .white : .black, ratio: 0.03)) }
    /// 悬浮/标签条材质底色
    var elevatedBackground: SwiftUI.Color { SwiftUI.Color(nsColor: backgroundNSColor.mixed(with: isDark ? .white : .black, ratio: 0.06)) }
    /// 细分隔线/描边
    var borderColor: SwiftUI.Color { SwiftUI.Color(nsColor: (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.08)) }
    /// 次要文字
    var secondaryText: SwiftUI.Color { SwiftUI.Color(nsColor: foregroundNSColor.withAlphaComponent(0.55)) }
    /// 强调色低透明填充(选中行)
    var accentSoft: SwiftUI.Color { accentColor.opacity(0.16) }

    /// 窗口应使用的外观(强制,以免深色主题在浅色系统里露出灰边)
    var appearanceName: NSAppearance.Name { isDark ? .darkAqua : .aqua }
}

extension TerminalTheme {

    /// 默认:精调深色,深靛蓝近黑底 + 柔和靛色强调(Linear/Things 3 气质)
    static let midnight = TerminalTheme(
        id: "berth-midnight",
        name: String(localized: "Berth 午夜"),
        isDark: true,
        background: "#0F1117",
        foreground: "#E6E8EE",
        cursor: "#8C9CF9",
        selection: "#2A3350",
        accent: "#7C8AF7",
        ansi: [
            "#2A2E3A", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#FFFFFF",
        ]
    )

    /// 精调深色(One Dark 气质)
    static let berthDark = TerminalTheme(
        id: "berth-dark",
        name: String(localized: "Berth 深色"),
        isDark: true,
        background: "#1B1E25",
        foreground: "#EBEEF2",
        cursor: "#56B6C2",
        selection: "#3E4451",
        accent: "#56B6C2",
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
        accent: "#C6A0F6",
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
        accent: "#2AA198",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ]
    )

    static let oneLight = TerminalTheme(
        id: "one-light",
        name: String(localized: "One Light(浅色)"),
        isDark: false,
        background: "#FAFAFA",
        foreground: "#383A42",
        cursor: "#526EFF",
        selection: "#E5E5E6",
        accent: "#4078F2",
        ansi: [
            "#383A42", "#E45649", "#50A14F", "#C18401", "#4078F2", "#A626A4", "#0184BC", "#A0A1A7",
            "#696C77", "#E45649", "#50A14F", "#C18401", "#4078F2", "#A626A4", "#0184BC", "#FFFFFF",
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        isDark: true,
        background: "#282A36",
        foreground: "#F8F8F2",
        cursor: "#F8F8F2",
        selection: "#44475A",
        accent: "#BD93F9",
        ansi: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ]
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        isDark: true,
        background: "#2E3440",
        foreground: "#D8DEE9",
        cursor: "#D8DEE9",
        selection: "#434C5E",
        accent: "#88C0D0",
        ansi: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ]
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        isDark: true,
        background: "#282828",
        foreground: "#EBDBB2",
        cursor: "#EBDBB2",
        selection: "#504945",
        accent: "#FE8019",
        ansi: [
            "#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ]
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        isDark: true,
        background: "#1A1B26",
        foreground: "#C0CAF5",
        cursor: "#C0CAF5",
        selection: "#283457",
        accent: "#7AA2F7",
        ansi: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ]
    )

    static let githubLight = TerminalTheme(
        id: "github-light",
        name: String(localized: "GitHub Light(浅色)"),
        isDark: false,
        background: "#FFFFFF",
        foreground: "#24292F",
        cursor: "#044289",
        selection: "#BBDFFF",
        accent: "#0969DA",
        ansi: [
            "#24292E", "#D73A49", "#28A745", "#DBAB09", "#0366D6", "#5A32A3", "#0598BC", "#6A737D",
            "#959DA5", "#CB2431", "#22863A", "#B08800", "#005CC5", "#5A32A3", "#3192AA", "#D1D5DA",
        ]
    )

    // MARK: 轻松活泼系

    /// 糖果霓虹(Snazzy):暗底高饱和糖果色,鲜亮跳脱
    static let snazzy = TerminalTheme(
        id: "snazzy",
        name: String(localized: "Snazzy 糖果"),
        isDark: true,
        background: "#282A36",
        foreground: "#EFF0EB",
        cursor: "#FF6AC1",
        selection: "#3E404A",
        accent: "#FF6AC1",
        ansi: [
            "#282A36", "#FF5C57", "#5AF78E", "#F3F99D", "#57C7FF", "#FF6AC1", "#9AEDFE", "#F1F1F0",
            "#686868", "#FF5C57", "#5AF78E", "#F3F99D", "#57C7FF", "#FF6AC1", "#9AEDFE", "#EFF0EB",
        ]
    )

    /// Catppuccin Mocha:软糖粉彩暗色,温柔不刺眼
    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        isDark: true,
        background: "#1E1E2E",
        foreground: "#CDD6F4",
        cursor: "#F5E0DC",
        selection: "#45475A",
        accent: "#CBA6F7",
        ansi: [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
        ]
    )

    /// 复古霓虹(Synthwave '84 气质):紫夜底 + 霓虹粉青
    static let synthwave = TerminalTheme(
        id: "synthwave-84",
        name: String(localized: "霓虹 '84"),
        isDark: true,
        background: "#262335",
        foreground: "#F4F0FF",
        cursor: "#F92AAD",
        selection: "#463465",
        accent: "#F92AAD",
        ansi: [
            "#3B3363", "#FE4450", "#72F1B8", "#FEDE5D", "#6D77B3", "#FF7EDB", "#03EDF9", "#F4F0FF",
            "#615C85", "#FE4450", "#72F1B8", "#FEDE5D", "#6D77B3", "#FF7EDB", "#03EDF9", "#FFFFFF",
        ]
    )

    /// Catppuccin Latte:奶油底粉彩,清淡活泼(浅色)
    static let catppuccinLatte = TerminalTheme(
        id: "catppuccin-latte",
        name: String(localized: "Catppuccin Latte(浅色)"),
        isDark: false,
        background: "#EFF1F5",
        foreground: "#4C4F69",
        cursor: "#DC8A78",
        selection: "#CCD0DA",
        accent: "#8839EF",
        ansi: [
            "#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
            "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC",
        ]
    )

    /// 晨雾玫瑰(Rosé Pine Dawn):米白底 + 灰紫玫瑰,柔和梦幻(浅色)
    static let rosePineDawn = TerminalTheme(
        id: "rose-pine-dawn",
        name: String(localized: "晨雾玫瑰(浅色)"),
        isDark: false,
        background: "#FAF4ED",
        foreground: "#575279",
        cursor: "#D7827E",
        selection: "#DFDAD9",
        accent: "#D7827E",
        ansi: [
            "#F2E9E1", "#B4637A", "#286983", "#EA9D34", "#56949F", "#907AA9", "#D7827E", "#575279",
            "#9893A5", "#B4637A", "#286983", "#EA9D34", "#56949F", "#907AA9", "#D7827E", "#575279",
        ]
    )

    /// Ayu Light:清爽白底 + 暖橙点缀,明快(浅色)
    static let ayuLight = TerminalTheme(
        id: "ayu-light",
        name: String(localized: "Ayu 清晨(浅色)"),
        isDark: false,
        background: "#FCFCFC",
        foreground: "#5C6166",
        cursor: "#FF9940",
        selection: "#E7F2FF",
        accent: "#FF9940",
        ansi: [
            "#010101", "#F07171", "#86B300", "#F2AE49", "#399EE6", "#A37ACC", "#4CBF99", "#C7C7C7",
            "#686868", "#F07171", "#86B300", "#F2AE49", "#399EE6", "#A37ACC", "#4CBF99", "#D1D1D1",
        ]
    )

    // MARK: 精选系(设计代理出品,全套过 WCAG 对比度实算:fg/bg ≥7、彩色 ≥3、色相间隔 ≥25°)

    /// 松烟墨:暖炭墨底 + 矿物颜料六色(朱砂/藤黄/竹绿/花青/胭脂/石绿),朱砂钤印作唯一高光。
    /// 与「玉版宣」共用色相体系,组成明暗成对的「墨与纸」双联。
    static let sumi = TerminalTheme(
        id: "berth-sumi",
        name: String(localized: "松烟墨 Sumi PRO"),
        isDark: true,
        background: "#1B1817",
        foreground: "#E8E1D2",
        cursor: "#D96A54",
        selection: "#3B342C",
        accent: "#D96A54",
        ansi: [
            "#262220", "#C75C4E", "#85A25A", "#C7A23C", "#6E9BC8", "#C4799F", "#5FAFA3", "#D3CBBB",
            "#746C60", "#E08573", "#A3BE7C", "#DCBB60", "#90B7DE", "#D99CBB", "#82CCC0", "#F4EEE1",
        ]
    )

    /// 玉版宣:暖白宣纸底 + 松烟墨色小楷,矿物印色与「松烟墨」同源(浅色)
    static let xuan = TerminalTheme(
        id: "berth-xuan",
        name: String(localized: "玉版宣 Xuan PRO(浅色)"),
        isDark: false,
        background: "#F8F3E6",
        foreground: "#3B342C",
        cursor: "#B4463A",
        selection: "#E2D5B7",
        accent: "#B4463A",
        ansi: [
            "#2F2A24", "#A63D33", "#5E7233", "#9A7514", "#2F5F94", "#9C3F72", "#23766C", "#E8E0CE",
            "#6B6153", "#BC4F41", "#6D8A3A", "#A8831A", "#3D74AE", "#B0538A", "#2F8B80", "#FBF8EF",
        ]
    )

    /// 夜泊琥珀:Vesper 式单强调色 —— 整屏只留一盏琥珀灯,其余六色雾面退后。
    /// 「深夜靠港」与 Berth(泊位)品牌同构。
    static let amberMooring = TerminalTheme(
        id: "amber-mooring",
        name: String(localized: "夜泊琥珀 Amber Mooring"),
        isDark: true,
        background: "#1E1A17",
        foreground: "#E9E2D7",
        cursor: "#FFC383",
        selection: "#3B332B",
        accent: "#FFC383",
        ansi: [
            "#322B25", "#D9837A", "#9DB489", "#E2B778", "#8CA7C4", "#C393B4", "#8CBBAF", "#CFC6B9",
            "#695F55", "#EA9C93", "#B4C99F", "#F0CC93", "#A8BFD9", "#D8ACC9", "#A5D2C5", "#F3EDE3",
        ]
    )

    /// 祖母绿圣殿:近墨深翠黑底,宝石定调的六色(红宝石/祖母绿/金绿柱石/蓝宝石/紫水晶/绿松石),
    /// 内置阵容中唯一的绿色系,对比度工程全场最强(fg/bg 16:1)
    static let emeraldSanctum = TerminalTheme(
        id: "emerald-sanctum",
        name: String(localized: "祖母绿圣殿 Emerald"),
        isDark: true,
        background: "#0D1712",
        foreground: "#E4F4EA",
        cursor: "#4FE3A7",
        selection: "#1F3D2E",
        accent: "#3DE3A0",
        ansi: [
            "#16281E", "#F16581", "#52DE74", "#E5C158", "#64A8F7", "#C687F0", "#38D9C8", "#CEE7D9",
            "#5F7A6B", "#FF8CA1", "#74EE9A", "#F7D97E", "#8FC2FF", "#DCA9FF", "#64EEDD", "#F2FBF6",
        ]
    )

    static let builtIn: [TerminalTheme] = [
        .midnight, .berthDark, .sumi, .amberMooring, .emeraldSanctum,
        .tokyoNight, .catppuccinMacchiato, .dracula, .nord, .gruvboxDark,
        .solarizedDark, .snazzy, .catppuccinMocha, .synthwave,
        .xuan, .oneLight, .githubLight, .catppuccinLatte, .rosePineDawn, .ayuLight,
    ]
}

/// 主题状态:持有当前主题,负责应用到 TerminalView(含 live 切换所有活跃会话)
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var current: TerminalTheme

    init() {
        let savedID = UserDefaults.standard.string(forKey: SettingsKeys.terminalTheme)
        current = TerminalTheme.builtIn.first { $0.id == savedID } ?? .midnight
    }

    func select(id: String) {
        guard let theme = TerminalTheme.builtIn.first(where: { $0.id == id }) else { return }
        current = theme
        UserDefaults.standard.set(theme.id, forKey: SettingsKeys.terminalTheme)
        for session in SessionManager.shared.sessions {
            apply(to: session.terminalView)
        }
        applyWindowChrome()
    }

    /// 强制整个 app(含工具栏/标题栏/未着色区域)跟随主题深浅,不受系统浅色模式影响
    func applyWindowChrome() {
        NSApplication.shared.appearance = NSAppearance(named: current.appearanceName)
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

    /// 在 sRGB 空间与另一色按比例混合(0 = 自身,1 = other)
    func mixed(with other: NSColor, ratio: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let t = max(0, min(1, ratio))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        )
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
