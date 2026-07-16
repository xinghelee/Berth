import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 基础设置(M1)。M2 扩展:主题、字体族、scrollback、快捷键、安全策略等。
struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(SettingsKeys.requireTouchIDForKeys) private var requireTouchID = true
    @State private var themeStore = ThemeStore.shared
    @State private var dataMessage: String?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Form {
            Section("终端") {
                Picker("主题", selection: Binding(
                    get: { themeStore.current.id },
                    set: { themeStore.select(id: $0) }
                )) {
                    ForEach(themeStore.allThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                HStack {
                    Button("导入 iTerm2 主题…") { importTheme() }
                    if themeStore.imported.contains(where: { $0.id == themeStore.current.id }) {
                        Button("删除当前导入主题", role: .destructive) {
                            themeStore.removeImported(id: themeStore.current.id)
                        }
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
            Section("数据") {
                HStack {
                    Button("导出备份…") { exportBackup() }
                    Button("导入备份…") { importBackup() }
                }
                Text("备份为 JSON,只含主机/分组/转发/代理结构;密码、passphrase、私钥在 Keychain,不会导出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dataMessage {
                    Text(dataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("设置")
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors") ?? .data, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let theme = try ITermColorsImporter.theme(from: data, name: url.lastPathComponent)
            themeStore.addImported(theme)
            dataMessage = "已导入主题「\(theme.name)」"
        } catch {
            dataMessage = "导入主题失败:\(error.localizedDescription)"
        }
    }

    private func exportBackup() {
        do {
            let data = try BackupService.export(context: modelContext)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Berth-备份.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                dataMessage = "已导出到 \(url.lastPathComponent)"
            }
        } catch {
            dataMessage = "导出失败:\(error.localizedDescription)"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try BackupService.import(data, context: modelContext)
            dataMessage = "已导入:新增 \(result.hosts) 台主机、\(result.groups) 个分组(重复项已跳过)"
        } catch {
            dataMessage = "导入失败:\(error.localizedDescription)"
        }
    }
}
