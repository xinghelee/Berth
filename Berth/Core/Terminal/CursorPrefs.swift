import Foundation
import SwiftTerm

/// 终端光标偏好:形状(方块/竖线/下划线)× 是否闪烁。存 UserDefaults,改动即时应用到所有会话。
enum CursorPrefs {
    static let shapeBlock = "block"
    static let shapeBar = "bar"
    static let shapeUnderline = "underline"

    static func resolved() -> CursorStyle {
        let shape = UserDefaults.standard.string(forKey: SettingsKeys.cursorShape) ?? shapeBlock
        let blink = UserDefaults.standard.object(forKey: SettingsKeys.cursorBlink) as? Bool ?? true
        switch (shape, blink) {
        case (shapeBar, true): return .blinkBar
        case (shapeBar, false): return .steadyBar
        case (shapeUnderline, true): return .blinkUnderline
        case (shapeUnderline, false): return .steadyUnderline
        case (_, true): return .blinkBlock
        default: return .steadyBlock
        }
    }

    @MainActor
    static func apply(to view: SwiftTerm.TerminalView) {
        view.getTerminal().setCursorStyle(resolved())
    }

    @MainActor
    static func applyToAllSessions() {
        for session in SessionManager.shared.sessions {
            apply(to: session.terminalView)
        }
    }
}
