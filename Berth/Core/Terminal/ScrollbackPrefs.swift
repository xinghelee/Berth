import Foundation
import SwiftTerm

/// 终端回滚缓冲行数(issue #52)。SwiftTerm 默认只有 500 行,长输出往上翻就丢了。
/// 上限 10 万行与 ⌘F 搜索的扫描范围一致;行按需分配,短会话不会占满。
enum ScrollbackPrefs {
    static let defaultLines = 10_000
    static let choices = [1_000, 5_000, 10_000, 50_000, 100_000]

    static func resolved() -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.scrollbackLines)
        return choices.contains(stored) ? stored : defaultLines
    }

    /// 新建终端视图时设定
    @MainActor
    static func apply(to view: SwiftTerm.TerminalView) {
        view.getTerminal().changeScrollback(resolved())
    }

    #if os(macOS)
    /// 已开会话只扩不缩:缩小会从顶部裁行,而 SwiftTerm 这条路径不计入 totalLinesTrimmed,
    /// 会让 scroll-invariant 行号(命令跳转标记、搜索定位)整体错位。调小只对新会话生效。
    @MainActor
    static func growAllSessions() {
        let lines = resolved()
        for session in SessionManager.shared.sessions {
            let terminal = session.terminalView.getTerminal()
            if terminal.options.scrollback < lines {
                terminal.changeScrollback(lines)
            }
        }
    }
    #endif
}
