import AppKit
import SwiftTerm

/// 统一终端粘贴编码。bracketed paste 开启时，shell 会把整段内容留在编辑缓冲区，
/// 不会因中间换行而提前执行；用户确认内容后再自行回车。
enum TerminalPasteEncoder {
    static func encode(_ text: String, bracketed: Bool) -> String {
        bracketed ? "\u{1b}[200~\(text)\u{1b}[201~" : text
    }
}

/// 终端视图子类:粘贴保护 —— 多行粘贴或含危险命令(sudo/rm -rf/dd/mkfs 等)先弹预览确认,
/// 防止误粘贴直接执行。可在 设置 → 安全 关闭。
final class BerthTerminalView: SwiftTerm.TerminalView {
    /// 生产环境主机:任何粘贴都强制确认(不止多行/危险命令)
    var isProductionHost = false
    /// 本地 Shell 会话:粘贴文件/图片时转成本地路径写入命令行(SSH 会话无本地路径语义)
    var isLocalSession = false
    /// 所属会话 id:点击 pane 时在 AppKit 层接管模型焦点(SwiftUI 的 onTapGesture
    /// 在 macOS 15 上收不到被 NSView 消费的点击)
    var focusSessionID: UUID?
    /// 要焦点时视图还没挂进窗口(切标签后 SwiftUI 晚于下一拍才把新标签的视图挂回去),
    /// 记下来等 viewDidMoveToWindow 再拿(issue #41)
    private var wantsFocusOnAttach = false

    /// 让终端成为第一响应者;不在窗口里就推迟到挂进窗口时
    func requestFocus() {
        if let window {
            wantsFocusOnAttach = false
            window.makeFirstResponder(self)
        } else {
            wantsFocusOnAttach = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocusOnAttach, let window else { return }
        wantsFocusOnAttach = false
        // 挂载过程中别的视图(标签 chip 的事件层等)还可能抢一下,落定后再拿
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // SwiftTerm 默认 .overlay:独立 NSScroller 脱离 NSScrollView 后 overlay 滑块
        // 永远不会绘制(显隐动画由 NSScrollView 私有管理),但宽度仍被预留,
        // 表现为右侧空白条且看不到滚动位置(issue #8)。legacy 样式可正常绘制。
        scrollerStyle = .legacy
        subdueScroller()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        scrollerStyle = .legacy
        subdueScroller()
    }

    /// legacy 滑块跟随 appearance 画成亮灰,深色主题近黑背景下太扎眼,整体压暗融入正文
    private func subdueScroller() {
        subviews.first { $0 is NSScroller }?.alphaValue = 0.35
    }

    /// 点 pane 聚焦在 AppKit 层做:模型焦点(focusedID)与键盘焦点一起接管
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            if let id = focusSessionID {
                let manager = SessionManager.shared
                if manager.selectedID != id || window?.firstResponder !== self {
                    manager.focusPane(id)
                }
            }
        }
        super.mouseDown(with: event)
    }

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

        // 混合分屏:SSH 会话旁边跑本地命令(scp/rsync/kubectl)
        let localHItem = NSMenuItem(title: String(localized: "左右分屏(本地 Shell)"), action: #selector(berthSplitLocalHorizontal), keyEquivalent: "l")
        localHItem.keyEquivalentModifierMask = [.command, .option]
        localHItem.target = self
        localHItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(localHItem)

        let localVItem = NSMenuItem(title: String(localized: "上下分屏(本地 Shell)"), action: #selector(berthSplitLocalVertical), keyEquivalent: "l")
        localVItem.keyEquivalentModifierMask = [.command, .option, .shift]
        localVItem.target = self
        localVItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(localVItem)

        // issue #11:分屏不只能连当前主机 —— 子菜单列出全部主机任选
        MainActor.assumeIsolated {
            let hosts = SessionManager.shared.allKnownHosts()
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            guard !hosts.isEmpty else { return }
            for (title, symbol, axisTag) in [
                (String(localized: "左右分屏连接主机"), "rectangle.split.2x1", 0),
                (String(localized: "上下分屏连接主机"), "rectangle.split.1x2", 1),
            ] {
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for host in hosts {
                    let item = NSMenuItem(title: "\(host.label)(\(host.username)@\(host.hostname))",
                                          action: #selector(berthSplitWithHost(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = axisTag
                    item.representedObject = host.id
                    item.isEnabled = true
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }

        let closePaneItem = NSMenuItem(title: String(localized: "关闭此分屏"), action: #selector(berthClosePane), keyEquivalent: "")
        closePaneItem.target = self
        closePaneItem.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(closePaneItem)

        menu.addItem(.separator())

        // 选中报错丢给 AI 分析(无选区时禁用)
        let askAIItem = NSMenuItem(title: String(localized: "询问 AI"), action: #selector(berthAskAI), keyEquivalent: "")
        askAIItem.target = self
        askAIItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(askAIItem)

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
        askAIItem.isEnabled = !(getSelection() ?? "").isEmpty
        return menu
    }

    @objc private func berthAskAI() {
        guard let text = getSelection(), !text.isEmpty else { return }
        MainActor.assumeIsolated { SessionManager.shared.askAIAboutSelection(text) }
    }

    @objc private func berthCopyLastOutput() {
        MainActor.assumeIsolated { _ = SessionManager.shared.selected?.copyLastCommandOutput() }
    }

    @objc private func berthSplitWithHost(_ sender: NSMenuItem) {
        guard let hostID = sender.representedObject as? UUID else { return }
        let axis: SplitAxis = sender.tag == 0 ? .horizontal : .vertical
        MainActor.assumeIsolated {
            let manager = SessionManager.shared
            let all = manager.allKnownHosts()
            guard let host = all.first(where: { $0.id == hostID }) else { return }
            host.lastConnectedAt = Date()
            manager.splitFocused(axis: axis, spec: HostSpec.resolve(host, in: all))
        }
    }

    @objc private func berthSplitHorizontal() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .horizontal) }
    }

    @objc private func berthSplitVertical() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .vertical) }
    }

    @objc private func berthSplitLocalHorizontal() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocusedLocalShell(axis: .horizontal) }
    }

    @objc private func berthSplitLocalVertical() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocusedLocalShell(axis: .vertical) }
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
        let pb = NSPasteboard.general
        // 本地会话:Finder 文件贴转义路径、裸图片(截图)落盘临时 PNG 贴路径
        // (codex/claude 这类 TUI 靠路径接收图片;SwiftTerm 默认粘贴只认字符串会静默失败)。
        // SSH 会话不开:本地路径在远端无意义。
        if isLocalSession {
            if pb.availableType(from: [.fileURL]) != nil,
               let urls = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                sendAsPaste(urls.map { Self.shellEscaped($0.path) }.joined(separator: " "))
                return
            }
            if pb.string(forType: .string) == nil, let path = Self.saveClipboardImage(pb) {
                sendAsPaste(Self.shellEscaped(path))
                return
            }
        }
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.pasteProtection) as? Bool ?? true
        guard enabled,
              let text = pb.string(forType: .string),
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

    /// 路径粘贴不走 super.paste(那条路只认字符串),按终端当前括号粘贴模式自己包
    private func sendAsPaste(_ text: String) {
        let payload = TerminalPasteEncoder.encode(text, bracketed: getTerminal().bracketedPasteMode)
        MainActor.assumeIsolated {
            if let id = focusSessionID, let session = SessionManager.shared.session(id) {
                session.sendText(payload)
            } else {
                send(txt: payload)
            }
        }
    }

    /// 剪贴板图片落盘成临时 PNG(TIFF 转码),返回文件路径;没有图片返回 nil
    static func saveClipboardImage(_ pb: NSPasteboard) -> String? {
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff) {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berth-clipboard-\(UUID().uuidString.prefix(8)).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }

    /// 路径 shell 转义:安全字符集内原样,否则单引号包裹(内部 ' → '\'')
    static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@%~")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
