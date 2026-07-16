import SwiftUI

/// 基础设置(M1)。M2 扩展:主题、字体族、scrollback、快捷键、安全策略等。
struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true

    var body: some View {
        Form {
            Section("终端") {
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("设置")
    }
}
