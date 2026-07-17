import SwiftData
import SwiftUI

@main
struct BerthApp: App {
    private let container = Persistence.makeContainer()
    private let sessionManager = SessionManager.shared

    init() {
        // 启动即强制整个 app 跟随主题深浅,避免打开时先闪一下系统浅色
        ThemeStore.shared.applyWindowChrome()
        SessionManager.shared.modelContainer = container
    }

    var body: some Scene {
        WindowGroup("Berth") {
            MainWindowView()
                .environment(sessionManager)
                .task {
                    await M1AcceptanceTest.runIfRequested(container: container)
                    await M2AcceptanceTest.runIfRequested(container: container)
                    await M2AcceptanceTest.runReconnectIfRequested(container: container)
                    await M2AcceptanceTest.runKeyConnectIfRequested(container: container)
                    await M2AcceptanceTest.runJumpIfRequested(container: container)
                    await M2AcceptanceTest.runForwardIfRequested(container: container)
                    await M2AcceptanceTest.runProxyIfRequested(container: container)
                    await M2AcceptanceTest.runBackupIfRequested(container: container)
                    await M2AcceptanceTest.runAgentIfRequested(container: container)
                    await M2AcceptanceTest.runSFTPIfRequested(container: container)
                    await M2AcceptanceTest.runReuseIfRequested(container: container)
                    await M2AcceptanceTest.runKeychainProbeIfRequested()
                    await M2AcceptanceTest.runSFTPEditIfRequested()
                    // 自动化验收/临时库环境不做会话恢复
                    let env = ProcessInfo.processInfo.environment
                    if !env.keys.contains(where: { $0.hasPrefix("BERTH_") }) {
                        await SessionManager.shared.restoreSessions(container: container)
                    }
                }
        }
        .modelContainer(container)
        .commands {
            TerminalCommands()
        }

        // 密钥管理:独立小窗,不与终端争主窗口空间
        Window("密钥", id: "keys") {
            KeysListView()
                .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
                .background(WindowConfigurator(
                    appearanceName: ThemeStore.shared.current.appearanceName,
                    backgroundColor: ThemeStore.shared.current.backgroundNSColor,
                    keepsTitle: true
                ))
        }
        .windowResizability(.contentSize)
        .modelContainer(container)

        // 命令片段管理
        Window("命令片段", id: "snippets") {
            SnippetsListView()
                .environment(sessionManager)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 520)
                .background(WindowConfigurator(
                    appearanceName: ThemeStore.shared.current.appearanceName,
                    backgroundColor: ThemeStore.shared.current.backgroundNSColor,
                    keepsTitle: true
                ))
        }
        .modelContainer(container)

        Settings {
            SettingsView()
        }
    }
}

/// 终端快捷键。遵循规格:绝不占用 Ctrl 组合键,只用 ⌘。
/// ⌘W 在 File 菜单中先于系统 Close 项匹配,优先关闭标签页;无标签时走系统行为关窗口。
struct TerminalCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("快速连接…") {
                QuickConnectController.shared.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("命令面板…") {
                CommandPaletteController.shared.toggle()
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("新建标签页(复制当前连接)") {
                SessionManager.shared.duplicateCurrent()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("关闭 pane / 标签页") {
                let manager = SessionManager.shared
                if manager.selected != nil {
                    manager.requestCloseCurrent()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            ForEach(1..<10) { index in
                Button("标签页 \(index)") {
                    SessionManager.shared.select(index: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }

        CommandGroup(after: .textEditing) {
            Button("在终端中查找") {
                SessionManager.shared.requestSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("终端") {
            Button("服务器信息面板") {
                SessionManager.shared.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("SFTP 文件面板") {
                SessionManager.shared.isSFTPVisible.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("左右分屏") {
                SessionManager.shared.splitFocused(axis: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("上下分屏") {
                SessionManager.shared.splitFocused(axis: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("广播输入到所有分屏") {
                SessionManager.shared.toggleBroadcast()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Divider()

            Button("命令片段…") {
                // 有会话时切换右侧面板;无会话时打开管理窗口
                if SessionManager.shared.selected != nil {
                    SessionManager.shared.isSnippetsPanelVisible.toggle()
                } else {
                    openWindow(id: "snippets")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}
