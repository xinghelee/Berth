import AppKit
import SwiftTerm

/// 终端视图子类:粘贴保护 —— 多行粘贴或含危险命令(sudo/rm -rf/dd/mkfs 等)先弹预览确认,
/// 防止误粘贴直接执行。可在 设置 → 安全 关闭。
final class BerthTerminalView: SwiftTerm.TerminalView {
    /// 生产环境主机:任何粘贴都强制确认(不止多行/危险命令)
    var isProductionHost = false

    // MARK: - 右键菜单(复制/粘贴 + 分屏)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // SwiftTerm 未实现菜单校验,自动校验会把自定义项判为禁用;这里手动管理启用态
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(title: String(localized: "复制"), action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: String(localized: "粘贴"), action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let hItem = NSMenuItem(title: String(localized: "左右分屏"), action: #selector(berthSplitHorizontal), keyEquivalent: "d")
        hItem.target = self
        hItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        menu.addItem(hItem)

        let vItem = NSMenuItem(title: String(localized: "上下分屏"), action: #selector(berthSplitVertical), keyEquivalent: "d")
        vItem.keyEquivalentModifierMask = [.command, .shift]
        vItem.target = self
        vItem.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)
        menu.addItem(vItem)

        let closePaneItem = NSMenuItem(title: String(localized: "关闭此分屏"), action: #selector(berthClosePane), keyEquivalent: "")
        closePaneItem.target = self
        closePaneItem.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(closePaneItem)

        menu.addItem(.separator())

        // 复制上条命令输出(需命令集成;无输出时禁用)
        let copyOutputItem = NSMenuItem(title: String(localized: "复制上条命令输出"), action: #selector(berthCopyLastOutput), keyEquivalent: "")
        copyOutputItem.target = self
        copyOutputItem.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        menu.addItem(copyOutputItem)

        let findItem = NSMenuItem(title: String(localized: "查找…"), action: #selector(berthFind), keyEquivalent: "f")
        findItem.target = self
        menu.addItem(findItem)

        menu.items.forEach { $0.isEnabled = true }
        // 无可复制输出时禁用该项
        MainActor.assumeIsolated {
            copyOutputItem.isEnabled = SessionManager.shared.selected?.hasCommandOutput ?? false
        }
        return menu
    }

    @objc private func berthCopyLastOutput() {
        MainActor.assumeIsolated { _ = SessionManager.shared.selected?.copyLastCommandOutput() }
    }

    @objc private func berthSplitHorizontal() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .horizontal) }
    }

    @objc private func berthSplitVertical() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .vertical) }
    }

    @objc private func berthClosePane() {
        MainActor.assumeIsolated { SessionManager.shared.requestCloseCurrent() }
    }

    @objc private func berthFind() {
        MainActor.assumeIsolated { SessionManager.shared.requestSearch() }
    }

    // MARK: - 选中即复制 / 中键粘贴

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // 选中即复制(Unix 习惯,默认关):拖选结束后有选区就写入剪贴板
        let enabled = UserDefaults.standard.bool(forKey: SettingsKeys.copyOnSelect)
        guard enabled, let text = getSelection(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func otherMouseUp(with event: NSEvent) {
        // 中键粘贴(默认关):粘贴剪贴板内容,仍走粘贴保护
        if event.buttonNumber == 2,
           UserDefaults.standard.bool(forKey: SettingsKeys.middleClickPaste) {
            paste(self)
            return
        }
        super.otherMouseUp(with: event)
    }

    override func paste(_ sender: Any) {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.pasteProtection) as? Bool ?? true
        guard enabled,
              let text = NSPasteboard.general.string(forType: .string),
              (isProductionHost || Self.needsConfirmation(text)) else {
            super.paste(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "确认粘贴到终端?")
        alert.informativeText = Self.preview(text)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "粘贴"))
        alert.addButton(withTitle: String(localized: "取消"))
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
        let header = lines.count > 1 ? String(localized: "共 \(lines.count) 行:\n\n") : ""
        return String((header + shown).prefix(1200))
    }
}
