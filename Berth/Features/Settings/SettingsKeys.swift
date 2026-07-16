import Foundation

/// @AppStorage / UserDefaults 键名统一定义
enum SettingsKeys {
    static let terminalFontSize = "terminal.fontSize"
    static let confirmBeforeClosingTab = "terminal.confirmBeforeClosingTab"
    static let autoReconnect = "session.autoReconnect"
    static let terminalTheme = "terminal.theme"
    static let importedThemes = "terminal.importedThemes"
    static let requireTouchIDForKeys = "security.requireTouchIDForKeys"
}
