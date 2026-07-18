import CloudKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 基础设置(M1)。M2 扩展:主题、字体族、scrollback、快捷键、安全策略等。
struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.cursorShape) private var cursorShape = CursorPrefs.shapeBlock
    @AppStorage(SettingsKeys.cursorBlink) private var cursorBlink = true
    @AppStorage(SettingsKeys.copyOnSelect) private var copyOnSelect = false
    @AppStorage(SettingsKeys.middleClickPaste) private var middleClickPaste = false
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(SettingsKeys.requireTouchIDForKeys) private var requireTouchID = true
    @AppStorage(SettingsKeys.pasteProtection) private var pasteProtection = true
    @AppStorage(SettingsKeys.notifyLongCommand) private var notifyLongCommand = true
    @AppStorage(SettingsKeys.restoreSessions) private var restoreSessions = true
    @AppStorage(SettingsKeys.restoreWorkingDir) private var restoreWorkingDir = true
    @AppStorage(SettingsKeys.appLanguage) private var appLanguage = "system"
    @AppStorage(SettingsKeys.menuBarExtra) private var menuBarExtraEnabled = true
    @AppStorage(SettingsKeys.probeReachability) private var probeReachability = false
    @State private var themeStore = ThemeStore.shared
    @State private var dataMessage: String?
    @State private var syncAccountStatus: CKAccountStatus?
    @State private var showAcknowledgements = false
    @State private var languageChanged = false
    @Environment(\.modelContext) private var modelContext

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
                Picker("光标样式", selection: $cursorShape) {
                    Text("方块").tag(CursorPrefs.shapeBlock)
                    Text("竖线").tag(CursorPrefs.shapeBar)
                    Text("下划线").tag(CursorPrefs.shapeUnderline)
                }
                .pickerStyle(.segmented)
                Toggle("光标闪烁", isOn: $cursorBlink)
                Toggle("选中即复制到剪贴板", isOn: $copyOnSelect)
                Toggle("中键粘贴", isOn: $middleClickPaste)
                Text("⌘点击可打开终端里的链接;双击选词、三击选行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: cursorShape) { _, _ in CursorPrefs.applyToAllSessions() }
            .onChange(of: cursorBlink) { _, _ in CursorPrefs.applyToAllSessions() }
            Section("标签页") {
                Toggle("关闭有活跃连接的标签页前需要确认", isOn: $confirmBeforeClosingTab)
            }
            Section("会话") {
                Toggle("非主动断开时自动重连(指数退避)", isOn: $autoReconnect)
                Toggle("启动时恢复上次的标签页", isOn: $restoreSessions)
                Toggle("重连后自动 cd 回上次工作目录(需命令集成)", isOn: $restoreWorkingDir)
                Toggle("后台时长任务完成/响铃通知", isOn: $notifyLongCommand)
            }
            Section("安全") {
                Toggle("使用私钥连接前要求 Touch ID / 密码验证", isOn: $requireTouchID)
                Toggle("粘贴保护:多行或危险命令先确认", isOn: $pasteProtection)
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
            Section("通用") {
                Toggle("在菜单栏显示图标(会话切换 / 快速连接)", isOn: $menuBarExtraEnabled)
                Toggle("探测主机是否在线(侧栏状态条着色)", isOn: $probeReachability)
                    .onChange(of: probeReachability) { _, _ in HostReachability.shared.settingsChanged() }
                Text("每 30 秒对直连主机做一次 TCP 测活;跳板机/代理主机不探测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("iCloud 同步") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(syncStatusLabel)
                        .foregroundStyle(.secondary)
                }
                Text("主机、分组、端口转发、片段、模板与触发器经 iCloud 私有库自动同步;密码与私钥只在本机钥匙串,永不上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task { await refreshSyncStatus() }
            Section("语言") {
                Picker("界面语言", selection: $appLanguage) {
                    Text("跟随系统").tag("system")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: appLanguage) { _, newValue in
                    if newValue == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("语言更改在重启 Berth 后生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("立即重启") { relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }
            Section("关于") {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    LabeledContent("版本", value: version)
                }
                LabeledContent("第三方开源库") {
                    Button("查看协议…") { showAcknowledgements = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsView()
        }
        // 跟随主题:系统表单底色会被壁纸渗色(desktop tinting),与主窗口主题不搭
        .scrollContentBackground(.hidden)
        .background(themeStore.current.panelBackground)
        .tint(themeStore.current.accentColor)
        .frame(width: 460)
        .navigationTitle("设置")
    }

    private var syncStatusLabel: String {
        if ProcessInfo.processInfo.environment["BERTH_DISABLE_SYNC"] == "1" {
            return String(localized: "已停用(调试)")
        }
        switch syncAccountStatus {
        case .available: return String(localized: "已启用,随 iCloud 自动同步")
        case .noAccount: return String(localized: "未登录 iCloud 账号")
        case .restricted: return String(localized: "iCloud 账号受限")
        case .temporarilyUnavailable: return String(localized: "iCloud 暂不可用,稍后自动重试")
        case .couldNotDetermine, .none: return String(localized: "检查中…")
        @unknown default: return String(localized: "检查中…")
        }
    }

    private func refreshSyncStatus() async {
        let container = CKContainer(identifier: "iCloud.com.berthssh.app")
        syncAccountStatus = (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    private func exportBackup() {
        do {
            let data = try BackupService.export(context: modelContext)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = String(localized: "Berth-备份.json")
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                dataMessage = String(localized: "已导出到 \(url.lastPathComponent)")
            }
        } catch {
            dataMessage = String(localized: "导出失败:\(error.localizedDescription)")
        }
    }

    /// 语言切换后重启:先拉起新实例再退出当前实例
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
            dataMessage = String(localized: "已导入:新增 \(result.hosts) 台主机、\(result.groups) 个分组(重复项已跳过)")
        } catch {
            dataMessage = String(localized: "导入失败:\(error.localizedDescription)")
        }
    }
}
