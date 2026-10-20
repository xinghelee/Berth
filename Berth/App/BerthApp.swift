import AppKit
import SwiftData
import SwiftUI

/// NSStatusItem 必须等 NSApplicationMain 起来再建(App.init 里创建会偶发启动卡死)
final class BerthAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarItemController.shared.start()
        Task { _ = try? await SFTPDragStagingStore.shared.sweepStale() }
        Task.detached { _ = try? DownloadDestinationTransaction.sweepOrphans() }
    }
}

@main
struct BerthApp: App {
    @NSApplicationDelegateAdaptor(BerthAppDelegate.self) private var appDelegate
    private let container = Persistence.makeContainer()
    private let sessionManager = SessionManager.shared

    init() {
        // 旧位置的机密改为按需迁移(见 KeychainStore.adoptLegacyItem),启动时不再扫钥匙串
        // 尽早订阅 CloudKit 同步事件
        _ = CloudSyncMonitor.shared
        // 启动即强制整个 app 跟随主题深浅,避免打开时先闪一下系统浅色
        ThemeStore.shared.applyWindowChrome()
        SessionManager.shared.modelContainer = container
    }

    var body: some Scene {
        WindowGroup("Berth") {
            MainWindowView()
                .environment(sessionManager)
                .task {
                    #if DEBUG
                    // 验收 harness 只进 Debug 构建:Release 不该带「环境变量即自动信任主机密钥 /
                    // dump 终端缓冲 / 截窗口」的入口;跑完恢复 defaults 快照
                    AcceptanceDefaults.protectIfAutomated()
                    await M1AcceptanceTest.runIfRequested(container: container)
                    await M2AcceptanceTest.runIfRequested(container: container)
                    await M2AcceptanceTest.runReconnectIfRequested(container: container)
                    await M2AcceptanceTest.runKeyConnectIfRequested(container: container)
                    await M2AcceptanceTest.runJumpIfRequested(container: container)
                    await M2AcceptanceTest.runForwardIfRequested(container: container)
                    await M2AcceptanceTest.runRuntimeForwardIfRequested(container: container)
                    await M2AcceptanceTest.runProxyIfRequested(container: container)
                    await M2AcceptanceTest.runBackupIfRequested(container: container)
                    await M2AcceptanceTest.runAgentIfRequested(container: container)
                    await M2AcceptanceTest.runSFTPIfRequested(container: container)
                    await M2AcceptanceTest.runSFTPNavIfRequested(container: container)
                    await M2AcceptanceTest.runSwitchUserIfRequested(container: container)
                    await M2AcceptanceTest.runReuseIfRequested(container: container)
                    await M2AcceptanceTest.runKbdIntIfRequested(container: container)
                    await M2AcceptanceTest.runKeychainProbeIfRequested()
                    await M2AcceptanceTest.runSFTPEditIfRequested()
                    await M2AcceptanceTest.runDropUploadIfRequested()
                    await M2AcceptanceTest.runAICommandIfRequested(container: container)
                    await M2AcceptanceTest.runAIChatIfRequested(container: container)
                    await LocalShellAcceptanceTest.runIfRequested()
                    await LivenessAcceptanceTest.runIfRequested()
                    await DashboardAcceptanceTest.runIfRequested(container: container)
                    // 并发跑:不挡在启动链前头,否则截不到会话恢复后的画面
                    Task { await WindowSnapshot.runIfRequested() }
                    Task { await SettingsContextProbe.runIfRequested() }
                    await DemoScene.runIfRequested(container: container)
                    #endif
                    // 自动化验收/临时库环境不做会话恢复,也不发检查更新请求
                    let env = ProcessInfo.processInfo.environment
                    if !env.keys.contains(where: { $0.hasPrefix("BERTH_") }) {
                        UpdateChecker.shared.startAutomaticChecks()
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

        // 仪表盘:所有主机的资源状态一屏看完(采集只在窗口开着时进行)
        Window("仪表盘", id: "dashboard") {
            DashboardView()
                .environment(sessionManager)
                .frame(minWidth: 660, idealWidth: 980, minHeight: 420, idealHeight: 680)
                .background(WindowConfigurator(
                    appearanceName: ThemeStore.shared.current.appearanceName,
                    backgroundColor: ThemeStore.shared.current.backgroundNSColor,
                    keepsTitle: true
                ))
        }
        .modelContainer(container)

        // 会话模板:保存/恢复整套标签+分屏布局
        Window("会话模板", id: "workspaces") {
            WorkspacesListView()
                .environment(sessionManager)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 320, idealHeight: 420)
                .background(WindowConfigurator(
                    appearanceName: ThemeStore.shared.current.appearanceName,
                    backgroundColor: ThemeStore.shared.current.backgroundNSColor,
                    keepsTitle: true
                ))
        }
        .modelContainer(container)

        // 输出触发器:正则匹配终端输出发通知
        Window("输出触发器", id: "triggers") {
            TriggersListView()
                .frame(minWidth: 440, idealWidth: 480, minHeight: 320, idealHeight: 420)
                .background(WindowConfigurator(
                    appearanceName: ThemeStore.shared.current.appearanceName,
                    backgroundColor: ThemeStore.shared.current.backgroundNSColor,
                    keepsTitle: true
                ))
        }
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

        // ⚠️ 必须挂 .modelContainer:Settings scene 不继承其他场景的环境,漏挂时
        // SwiftUI 会兜一个指向 /dev/null 的空容器(不崩、fetch 永远为空),
        // 设置页的备份导出就会写出没有任何主机的 JSON(issue #15)
        Settings {
            SettingsView()
        }
        .modelContainer(container)

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

            Button("新建本地 Shell") {
                SessionManager.shared.open(spec: .localShell())
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

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

            Button("上一条命令") {
                SessionManager.shared.selected?.jumpToPreviousCommand()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("下一条命令") {
                SessionManager.shared.selected?.jumpToNextCommand()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button("复制上条命令输出") {
                SessionManager.shared.selected?.copyLastCommandOutput()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandMenu("终端") {
            Button("服务器信息面板") {
                SessionManager.shared.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(SessionManager.shared.selected?.spec.isLocal == true)

            Button("SFTP 文件面板") {
                SessionManager.shared.isSFTPVisible.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(SessionManager.shared.selected?.spec.isLocal == true)

            Button("左右分屏") {
                SessionManager.shared.splitFocused(axis: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("上下分屏") {
                SessionManager.shared.splitFocused(axis: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("左右分屏(本地 Shell)") {
                SessionManager.shared.splitFocusedLocalShell(axis: .horizontal)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button("上下分屏(本地 Shell)") {
                SessionManager.shared.splitFocusedLocalShell(axis: .vertical)
            }
            .keyboardShortcut("l", modifiers: [.command, .option, .shift])

            Button("广播输入到所有分屏") {
                SessionManager.shared.toggleBroadcast()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Divider()

            Button(SessionManager.shared.selected?.isLogging == true ? "停止记录会话" : "记录会话到文件…") {
                SessionManager.shared.toggleSessionLogging()
            }

            Divider()

            // 主窗口内切换(⌘0);要常驻第二块屏的从仪表盘工具条撕成独立窗口
            Button(SessionManager.shared.isDashboardVisible ? "返回终端" : "仪表盘") {
                SessionManager.shared.isDashboardVisible.toggle()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("仪表盘(新窗口)…") {
                // 撕出去了就把主窗口还给终端,别留两份一样的仪表盘
                SessionManager.shared.isDashboardVisible = false
                openWindow(id: "dashboard")
            }

            Button("会话模板…") {
                openWindow(id: "workspaces")
            }

            Button("输出触发器…") {
                openWindow(id: "triggers")
            }

            Button("命令片段…") {
                // 有会话时切换右侧面板;无会话时打开管理窗口
                if SessionManager.shared.selected != nil {
                    SessionManager.shared.isSnippetsPanelVisible.toggle()
                } else {
                    openWindow(id: "snippets")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("AI 助手面板") {
                SessionManager.shared.isAIPanelVisible.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("询问 AI(选中的内容)") {
                let manager = SessionManager.shared
                if let text = manager.selected?.terminalView.getSelection() {
                    manager.askAIAboutSelection(text)
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }
    }
}
