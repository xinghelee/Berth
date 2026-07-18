import AppKit
import Foundation
import SwiftData

/// 官网/文档素材场景:BERTH_DEMO_SCENE=1 时(配合 BERTH_TRANSIENT_STORE=1)
/// 在内存库种一组演示主机,连接本地 test sshd,依次摆出几个功能场景,
/// 每个场景截一张图到 BERTH_SNAPSHOT_DIR。
/// 截图走 CGWindowList 组合本 app 的窗口(含浮层面板),无需屏幕录制权限;
/// 全部主机信息均为虚构,不含任何真实服务器地址。
@MainActor
enum DemoScene {

    static func runIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_DEMO_SCENE"] == "1",
              let hostAddr = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dir = env["BERTH_SNAPSHOT_DIR"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        ThemeStore.shared.select(id: "nord")

        // 侧栏演示主机(除 atlas-prod 外均为摆设,不发起连接)
        let context = ModelContext(container)
        let production = HostGroup(name: "Production", sortOrder: 0)
        let homelab = HostGroup(name: "Homelab", sortOrder: 1)
        context.insert(production)
        context.insert(homelab)

        let real = Host(label: "atlas-01", hostname: hostAddr, port: port, username: user,
                        group: production, tagColor: .blue)
        real.osName = "Alpine Linux"
        context.insert(real)

        let extras: [(String, String, String, TagColor, HostGroup, String)] = [
            ("atlas-staging", "staging.internal", "ops", .orange, production, "Ubuntu 24.04"),
            ("edge-gateway", "edge.internal", "ops", .blue, production, "Debian 12"),
            ("pve-lab", "pve.lab", "root", .green, homelab, "Proxmox VE"),
            ("build-runner", "runner.lab", "ci", .purple, homelab, "Ubuntu 24.04"),
        ]
        for (index, entry) in extras.enumerated() {
            let host = Host(label: entry.0, hostname: entry.1, port: 22, username: entry.2,
                            group: entry.4, tagColor: entry.3, sortOrder: index + 1)
            host.osName = entry.5
            context.insert(host)
        }

        do {
            try KeychainStore.save(password, account: KeychainStore.passwordAccount(for: real.id))
            try context.save()
        } catch { return }

        let manager = SessionManager.shared
        let session = manager.open(spec: HostSpec(host: real))
        guard await waitForConnected(session, timeout: 20) else { return }

        // 基础场景:先分屏定宽,再在各 pane 跑演示命令,避免 resize 重排错乱
        try? await Task.sleep(for: .seconds(1))
        manager.splitFocused(axis: .horizontal)
        try? await Task.sleep(for: .milliseconds(800))
        if let side = manager.selected, side !== session {
            if await waitForConnected(side, timeout: 15) {
                try? await Task.sleep(for: .milliseconds(600))
                side.sendText("htop\n")
            }
        }
        try? await Task.sleep(for: .milliseconds(600))
        session.sendText("clear && fastfetch\n")
        try? await Task.sleep(for: .seconds(2))

        // 外部遥控:窗口号写盘供 screencapture -l 使用;cmd.txt 驱动场景切换
        if let win = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) {
            try? String(win.windowNumber).write(to: outDir.appendingPathComponent("windowid.txt"),
                                                atomically: true, encoding: .utf8)
        }
        try? "ready".write(to: outDir.appendingPathComponent("READY"), atomically: true, encoding: .utf8)
        startCommandLoop(outDir: outDir, manager: manager)

        // 密码只为本场景服务,不留在真实 Keychain
        KeychainStore.deleteSecrets(for: real.id)
    }

    /// 轮询 cmd.txt:sftp-on/sftp-off/inspector-on/inspector-off/palette/snap <名字>
    private static func startCommandLoop(outDir: URL, manager: SessionManager) {
        let cmdFile = outDir.appendingPathComponent("cmd.txt")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let raw = try? String(contentsOf: cmdFile, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: cmdFile)
                let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                switch cmd {
                case "sftp-on": manager.isSFTPVisible = true
                case "sftp-off": manager.isSFTPVisible = false
                case "inspector-on": manager.isInspectorVisible = true
                case "inspector-off": manager.isInspectorVisible = false
                case "palette": CommandPaletteController.shared.toggle()
                default:
                    if cmd.hasPrefix("snap ") {
                        capture(to: outDir.appendingPathComponent(String(cmd.dropFirst(5)) + ".png"))
                    }
                }
            }
        }
    }

    private static func waitForConnected(_ session: TerminalSession, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.hostKeyPrompt != nil {
                session.resolveHostKeyPrompt(accepted: true)
            }
            if case .connected = session.state { return true }
            if case .disconnected = session.state { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// 组合截取本 app 的所有可见窗口(主窗 + 浮层),范围取主窗 frame。
    /// 用 cacheDisplay 让各窗口自绘(app 画自己,无需屏幕录制权限),再按窗口位置合成。
    private static func capture(to file: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { return }
        let mainFrame = main.frame
        let scale = main.backingScaleFactor
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(mainFrame.width * scale),
            pixelsHigh: Int(mainFrame.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        canvas.size = mainFrame.size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        NSGraphicsContext.current = ctx

        let windows = NSApp.windows
            .filter { $0.isVisible && $0.frame.intersects(mainFrame) }
            .sorted { $0.orderedIndex > $1.orderedIndex } // 底层在前,浮层最后画
        for window in windows {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let origin = CGPoint(x: window.frame.minX - mainFrame.minX,
                                 y: window.frame.minY - mainFrame.minY)
            rep.draw(in: CGRect(origin: origin, size: window.frame.size),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        guard let data = canvas.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: file)
    }
}
