#if DEBUG
import AppKit

/// 窗口自截图:BERTH_WINDOW_SNAPSHOT=<png 路径> 时,启动后延时把主窗口(含标题栏)渲染成 PNG。
/// 走 NSView 自身的 cacheDisplay(app 画自己的视图层级),无需屏幕录制权限;
/// BERTH_SNAPSHOT_OPEN_LOCAL=1 可先开一个本地 Shell 再截;
/// BERTH_SNAPSHOT_LOCAL_BOOKMARK=1 造并打开一个本地 Shell 书签;
/// BERTH_SNAPSHOT_SPLIT=0.7 再左右分屏一个本地 Shell 并把分割比例设成 0.7。
/// 给自动化验收看界面用。
@MainActor
enum WindowSnapshot {
    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        // 启动参数版(-berth.windowSnapshot <路径>):不带 BERTH_ 环境变量,
        // 不会被启动逻辑当成自动化环境 —— 用于截「真实会话恢复」路径。
        // 只读 NSArgumentDomain,不读持久 defaults:否则一次 defaults write 就能让
        // 之后每次启动都把窗口(含终端内容)截图写到任意路径
        let argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let path = env["BERTH_WINDOW_SNAPSHOT"]
            ?? argumentDomain["berth.windowSnapshot"] as? String else { return }
        // 造工作空间演示数据:两个空间 + 三台摆设主机(配临时库,截侧栏分页条用)
        if env["BERTH_SNAPSHOT_SPACES"] == "1", let container = SessionManager.shared.modelContainer {
            let context = container.mainContext
            let work = HostGroup(name: "工作", sortOrder: 0)
            let personal = HostGroup(name: "个人", sortOrder: 1)
            context.insert(work)
            context.insert(personal)
            let seeds: [(String, String, String, HostGroup)] = [
                ("web-01", "10.0.0.11", "ops", work),
                ("db-01", "10.0.0.12", "ops", work),
                ("nas", "192.168.1.20", "me", personal),
            ]
            for (index, seed) in seeds.enumerated() {
                let host = Host(label: seed.0, hostname: seed.1, username: seed.2, sortOrder: index)
                context.insert(host)
                host.group = seed.3
            }
            try? context.save()
        }
        // issue #41:造一个本地 Shell 书签(配临时库)并打开,截侧栏书签行与书签标签
        if env["BERTH_SNAPSHOT_LOCAL_BOOKMARK"] == "1", let container = SessionManager.shared.modelContainer {
            let bookmark = Host(label: "系统日志", hostname: "localhost", port: 0, username: NSUserName())
            bookmark.isLocalShell = true
            bookmark.localDirectory = "/var/log"
            container.mainContext.insert(bookmark)
            try? container.mainContext.save()
            try? await Task.sleep(for: .seconds(1))
            _ = SessionManager.shared.open(spec: HostSpec(host: bookmark))
        }
        // 值即要开的本地 Shell 数量("1" 开一个,"5" 开五个,方便截多标签布局)
        if let count = Int(env["BERTH_SNAPSHOT_OPEN_LOCAL"] ?? ""), count > 0 {
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<count {
                _ = SessionManager.shared.open(spec: .localShell())
            }
        }
        // 打开检查器栏的某个面板(ai/sftp/info/docker/snippets),截右栏布局用
        if let raw = env["BERTH_SNAPSHOT_PANEL"],
           let panel = SessionManager.SidePanel(rawValue: raw) {
            try? await Task.sleep(for: .milliseconds(500))
            SessionManager.shared.activeSidePanel = panel
        }
        // 分屏 + 指定比例:验证分割线拖拽后的布局(issue #11-2)
        if let ratio = Double(env["BERTH_SNAPSHOT_SPLIT"] ?? "") {
            try? await Task.sleep(for: .seconds(1))
            let manager = SessionManager.shared
            manager.splitFocusedLocalShell(axis: .horizontal)
            if let tab = manager.selectedTab, case .branch(let id, _, _, _) = tab.root {
                tab.setRatio(ratio, for: id)
            }
        }
        // 往焦点会话灌文本(自动补回车):截「终端滚满内容」的布局,如 seq 1 200
        if let typed = env["BERTH_SNAPSHOT_TYPE"], !typed.isEmpty {
            try? await Task.sleep(for: .seconds(1.5))
            SessionManager.shared.selected?.sendText(typed + "\n")
        }
        let delay = Double(env["BERTH_SNAPSHOT_DELAY"] ?? "3") ?? 3
        try? await Task.sleep(for: .seconds(delay))
        capture(to: path)
        // issue #14:标题栏布局要连着看侧栏收/放两态 —— 再截 <path>.collapsed.png
        // 和 <path>.reexpanded.png,验证收起后标签条还在、展开后能复原
        if env["BERTH_SNAPSHOT_TOGGLE_SIDEBAR"] == "1" {
            for suffix in ["collapsed", "reexpanded"] {
                // sendAction 走按键响应链,app 不在前台会被静默丢弃 —— 先抢前台把窗口置 key
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.identifier == MainWindowRaiser.identifier }?
                    .makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: (path as NSString).deletingPathExtension + ".\(suffix).png")
            }
        }
        // 窗口缩放后的布局收敛(issue #14 右缘空白):改宽再截 <path>.resized.png
        if let width = Double(env["BERTH_SNAPSHOT_RESIZE"] ?? ""),
           let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier == MainWindowRaiser.identifier }) {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true, animate: false)
            try? await Task.sleep(for: .seconds(1.5))
            capture(to: (path as NSString).deletingPathExtension + ".resized.png")
        }
    }

    private static func capture(to path: String) {
        // 认准主窗口:溢出菜单/气泡之类的小窗也在 NSApp.windows 里,取 first 会截到它们
        let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = visible.first(where: { $0.identifier == MainWindowRaiser.identifier })
            ?? visible.max(by: { $0.frame.width < $1.frame.width }),
              let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
