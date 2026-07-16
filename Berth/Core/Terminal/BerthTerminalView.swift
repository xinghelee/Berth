import AppKit
import SwiftTerm

/// 终端视图子类:粘贴保护 —— 多行粘贴或含危险命令(sudo/rm -rf/dd/mkfs 等)先弹预览确认,
/// 防止误粘贴直接执行。可在 设置 → 安全 关闭。
final class BerthTerminalView: SwiftTerm.TerminalView {

    override func paste(_ sender: Any) {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.pasteProtection) as? Bool ?? true
        guard enabled,
              let text = NSPasteboard.general.string(forType: .string),
              Self.needsConfirmation(text) else {
            super.paste(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = "确认粘贴到终端?"
        alert.informativeText = Self.preview(text)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "粘贴")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            super.paste(sender)
        }
    }

    /// 多行,或单行但含高危命令片段
    static func needsConfirmation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sudo ") { return true }
        let dangerous = ["rm -rf", "rm -fr", "mkfs", "dd if=", "shutdown", "reboot", ":(){", "> /dev/sd", "chmod -r 777 /"]
        return dangerous.contains { lower.contains($0) }
    }

    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(12).joined(separator: "\n")
        if lines.count > 12 {
            shown += "\n…"
        }
        let header = lines.count > 1 ? "共 \(lines.count) 行:\n\n" : ""
        return String((header + shown).prefix(1200))
    }
}
