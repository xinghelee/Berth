import SwiftUI

/// 基础设置(M1)。M2 扩展:主题、字体族、scrollback、快捷键、安全策略等。
struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(SettingsKeys.requireTouchIDForKeys) private var requireTouchID = true
    @State private var themeStore = ThemeStore.shared

    var body: some View {
        Form {
            Section("终端") {
                Picker("主题", selection: Binding(
                    get: { themeStore.current.id },
                    set: { themeStore.select(id: $0) }
                )) {
                    ForEach(TerminalTheme.builtIn) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                HStack {
                    Text("字号")
                    Slider(value: $fontSize, in: 10...22, step: 1) {
                        Text("字号")
                    }
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("字号变更对新开的标签页生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("标签页") {
                Toggle("关闭有活跃连接的标签页前需要确认", isOn: $confirmBeforeClosingTab)
            }
            Section("会话") {
                Toggle("非主动断开时自动重连(指数退避)", isOn: $autoReconnect)
            }
            Section("安全") {
                Toggle("使用私钥连接前要求 Touch ID / 密码验证", isOn: $requireTouchID)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("设置")
    }
}
