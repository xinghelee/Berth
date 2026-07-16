import SwiftData
import SwiftUI

@main
struct BerthApp: App {
    private let container = Persistence.makeContainer()
    private let sessionManager = SessionManager.shared

    var body: some Scene {
        WindowGroup("Berth") {
            MainWindowView()
                .environment(sessionManager)
                .task { await M1AcceptanceTest.runIfRequested(container: container) }
        }
        .modelContainer(container)
        .commands {
            TerminalCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// 终端快捷键。遵循规格:绝不占用 Ctrl 组合键,只用 ⌘。
/// ⌘W 在 File 菜单中先于系统 Close 项匹配,优先关闭标签页;无标签时走系统行为关窗口。
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建标签页(复制当前连接)") {
                SessionManager.shared.duplicateCurrent()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("关闭标签页") {
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
    }
}
