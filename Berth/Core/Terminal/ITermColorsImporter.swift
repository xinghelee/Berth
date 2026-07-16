import Foundation

/// 解析 iTerm2 的 .itermcolors(plist,颜色分量 0–1)为 TerminalTheme。
enum ITermColorsImporter {

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func theme(from data: Data, name: String) throws -> TerminalTheme {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ImportError(message: "不是有效的 .itermcolors 文件")
        }

        func hex(_ key: String) -> String? {
            guard let dict = plist[key] as? [String: Any] else { return nil }
            let r = (dict["Red Component"] as? Double) ?? 0
            let g = (dict["Green Component"] as? Double) ?? 0
            let b = (dict["Blue Component"] as? Double) ?? 0
            return String(format: "#%02X%02X%02X",
                          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        guard let background = hex("Background Color"),
              let foreground = hex("Foreground Color") else {
            throw ImportError(message: ".itermcolors 缺少前景/背景色")
        }

        var ansi: [String] = []
        for i in 0..<16 {
            ansi.append(hex("Ansi \(i) Color") ?? (i < 8 ? foreground : background))
        }

        let cursor = hex("Cursor Color") ?? foreground
        let selection = hex("Selection Color") ?? "#3E4451"

        let cleanName = name.replacingOccurrences(of: ".itermcolors", with: "")
        let slug = "iterm-" + cleanName.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)

        return TerminalTheme(
            id: slug,
            name: cleanName,
            isDark: isDark(hex: background),
            background: background,
            foreground: foreground,
            cursor: cursor,
            selection: selection,
            accent: cursor,
            ansi: ansi
        )
    }

    /// 由背景亮度判断深浅
    private static func isDark(hex: String) -> Bool {
        var text = hex
        if text.hasPrefix("#") { text = String(text.dropFirst()) }
        guard text.count == 6, let value = Int(text, radix: 16) else { return true }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return luminance < 0.5
    }
}
