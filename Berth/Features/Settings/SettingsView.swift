import CloudKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口内的共享路由。SettingsLink 负责打开系统设置窗口,这里负责把已打开或
/// 即将打开的 SettingsView 定位到调用方指定的分类。
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    private(set) var tab: SettingsTab

    init(tab: SettingsTab = .terminal) {
        self.tab = tab
    }

    func select(_ tab: SettingsTab) {
        self.tab = tab
    }
}

/// 基础设置(M1)。M2 扩展:主题、字体族、scrollback、快捷键、安全策略等。
struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.tabFontSize) private var tabFontSize: Double = 12
    @AppStorage(SettingsKeys.terminalFontFamily) private var fontFamily = ""
    private let monoFamilies = TerminalFontPrefs.availableMonospacedFamilies()
    @AppStorage(SettingsKeys.cursorShape) private var cursorShape = CursorPrefs.shapeBlock
    @AppStorage(SettingsKeys.cursorBlink) private var cursorBlink = true
    @AppStorage(SettingsKeys.copyOnSelect) private var copyOnSelect = false
    @AppStorage(SettingsKeys.middleClickPaste) private var middleClickPaste = false
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.doubleClickNewConnection) private var doubleClickNewConnection = true
    @AppStorage(SettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(SettingsKeys.requireTouchIDForKeys) private var requireTouchID = true
    @AppStorage(SettingsKeys.pasteProtection) private var pasteProtection = true
    @AppStorage(SettingsKeys.notifyLongCommand) private var notifyLongCommand = true
    @AppStorage(SettingsKeys.restoreSessions) private var restoreSessions = true
    @AppStorage(SettingsKeys.restoreWorkingDir) private var restoreWorkingDir = true
    @AppStorage(SettingsKeys.appLanguage) private var appLanguage = "system"
    @AppStorage(SettingsKeys.menuBarExtra) private var menuBarExtraEnabled = true
    @AppStorage(SettingsKeys.probeReachability) private var probeReachability = false
    @AppStorage(SettingsKeys.aiModel) private var aiModel = ""
    @AppStorage(SettingsKeys.aiBaseURL) private var aiBaseURL = ""
    @AppStorage(SettingsKeys.aiAutoRunCommands) private var aiAutoRun = false
    @AppStorage(SettingsKeys.aiAPIFormat) private var aiFormat = AISettings.APIFormat.anthropic.rawValue
    @AppStorage(SettingsKeys.aiMaxCommandRounds) private var aiMaxRounds = AISettings.defaultMaxCommandRounds
    @AppStorage(SettingsKeys.aiCustomInstructions) private var aiCustomInstructions = ""
    @AppStorage(SettingsKeys.autoCheckUpdates) private var autoCheckUpdates = true
    @AppStorage(SettingsKeys.localShellPath) private var localShellPath = ""
    @AppStorage(SettingsKeys.externalEditorPath) private var externalEditorPath = ""
    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true
    @State private var aiProviderID = AIProvider.all[0].id
    @State private var aiModelIsCustom = false
    @State private var modelCatalog = AIModelCatalog.shared
    @State private var navigation = SettingsNavigation.shared
    @State private var aiKeyDraft = ""
    @State private var aiKeySaved = ""
    @State private var aiKeyNote: String?
    @State private var themeStore = ThemeStore.shared
    @State private var dataMessage: String?
    @State private var syncAccountStatus: CKAccountStatus?
    @State private var syncMonitor = CloudSyncMonitor.shared
    @State private var syncNote: String?
    @State private var showAcknowledgements = false
    @State private var languageChanged = false
    @State private var isShowingConfigImport = false
    @State private var configService = SSHConfigService.shared
    @State private var importPolicy = SSHConfigImportPolicy.shared
    @Environment(\.modelContext) private var modelContext

    /// 设置页里一句话交代当前 config 主机的显示范围
    private var configImportSummary: String {
        let total = configService.candidates.count
        guard total > 0 else { return String(localized: "没有找到可导入的主机") }
        switch importPolicy.mode {
        case .all:
            return String(localized: "显示全部 \(total) 个主机")
        case .selected:
            let shown = configService.candidates.filter { importPolicy.includes(alias: $0.alias) }.count
            return String(localized: "显示 \(shown) / \(total) 个主机")
        case .none:
            return String(localized: "不显示 config 主机(共 \(total) 个)")
        }
    }

    var body: some View {
        // 不用 NavigationSplitView:设置窗不需要导航语义,自绘两栏才能完全跟随终端主题
        // (系统侧栏的选中态是固定蓝,和 20 套主题里的强调色对不上)
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(theme.borderColor)
            Form {
                switch navigation.tab {
                case .terminal: terminalPage
                case .session: sessionPage
                case .ai: aiPage
                case .security: securityPage
                case .data: dataPage
                case .general: generalPage
                }
            }
            .formStyle(.grouped)
            // 跟随主题:系统表单底色会被壁纸渗色(desktop tinting),与主窗口主题不搭
            .scrollContentBackground(.hidden)
            .background(theme.chromeBackground)
        }
        .frame(width: 840, height: 600)
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsView()
        }
        .sheet(isPresented: $isShowingConfigImport) {
            SSHConfigImportSheet(isWelcome: false)
        }
        .tint(theme.accentColor)
        .navigationTitle("设置")
        .onAppear {
            // issue #15 诊断探针,仅 BERTH_SETTINGS_PROBE 时活动
            #if DEBUG
            SettingsContextProbe.report(settingsContext: modelContext)
            #endif
        }
    }

    private var theme: TerminalTheme { themeStore.current }

    /// 左栏:大图标 + 文字,选中态走主题强调色
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                SettingsTabRow(item: item, isSelected: navigation.tab == item) {
                    navigation.select(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panelBackground)
    }

    @ViewBuilder
    private var terminalPage: some View {
            Section {
                Picker("主题", selection: Binding(
                    get: { themeStore.current.id },
                    set: { themeStore.select(id: $0) }
                )) {
                    ForEach(TerminalTheme.builtIn) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Toggle("透明毛玻璃(侧栏与标题栏透出桌面)", isOn: $translucentChrome)
                Text("终端区始终保持不透明,保证输出可读。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("字体", selection: $fontFamily) {
                    Text("系统等宽(SF Mono)").tag("")
                    if !fontFamily.isEmpty && !monoFamilies.contains(fontFamily) {
                        Text(fontFamily).tag(fontFamily)
                    }
                    ForEach(monoFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .onChange(of: fontFamily) { _, _ in TerminalFontPrefs.applyToAllSessions() }
                Text("显示 Nerd Font 图标需选择已安装的 Nerd 字体(如 JetBrainsMono Nerd Font)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(value: $fontSize, in: 10...22, step: 1) {
                        Text("字号")
                    }
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                // 即时应用到所有已开会话(行列数变化会经 resize 流程同步给 PTY)
                .onChange(of: fontSize) { _, _ in TerminalFontPrefs.applyToAllSessions() }
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
            Section("本地 Shell") {
                TextField("Shell 路径", text: $localShellPath, prompt: Text(verbatim: LocalShell.loginShell()))
                    .autocorrectionDisabled()
                Text("本地 Shell 标签页(⇧⌘T / ⌘K)所用的 shell。留空使用登录 shell;对新开的本地会话生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("远程文件编辑") {
                HStack {
                    Text(externalEditorDisplayName)
                        .foregroundStyle(externalEditorPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    if !externalEditorPath.isEmpty {
                        Button("使用系统默认") { externalEditorPath = "" }
                    }
                    Button("选择…") { chooseExternalEditor() }
                }
                Text("SFTP 面板双击远端文件时,下载到本地临时目录后用来打开的应用。留空则 .yaml/.json/.md 等纯文本类文件交给 macOS 为该类型指定的默认应用(仅限能编辑纯文本的程序,浏览器除外);脚本、网页及其他类型固定用系统纯文本编辑器打开,远端文件名不会触发执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private var externalEditorDisplayName: String {
        guard !externalEditorPath.isEmpty else { return String(localized: "系统默认") }
        return FileManager.default.displayName(atPath: externalEditorPath)
    }

    private func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            externalEditorPath = url.path
        }
    }

    @ViewBuilder
    private var sessionPage: some View {
            Section("标签页") {
                HStack {
                    Slider(value: $tabFontSize, in: 11...18, step: 1) {
                        Text("标签字号")
                    }
                    Text("\(Int(tabFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("关闭有活跃连接的标签页前需要确认", isOn: $confirmBeforeClosingTab)
                Toggle("双击主机行再开一条同主机连接", isOn: $doubleClickNewConnection)
            }
            Section("会话") {
                Toggle("非主动断开时自动重连(指数退避)", isOn: $autoReconnect)
                Toggle("启动时恢复上次的标签页", isOn: $restoreSessions)
                Toggle("重连后自动 cd 回上次工作目录(需命令集成)", isOn: $restoreWorkingDir)
                Toggle("后台时长任务完成/响铃通知", isOn: $notifyLongCommand)
            }
    }

    @ViewBuilder
    private var aiPage: some View {
            Section {
                Picker("供应商", selection: $aiProviderID) {
                    Section("官方 / 云厂商") {
                        ForEach(AIProvider.vendors) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    Section("聚合与中转") {
                        ForEach(AIProvider.aggregators) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    Section("本地") {
                        ForEach(AIProvider.local) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    Divider()
                    Text("自定义").tag(AIProvider.customID)
                }
                .onChange(of: aiProviderID) { _, id in applyProvider(id) }
                HStack {
                    SecureField("API Key", text: $aiKeyDraft, prompt: Text(verbatim: "sk-…"))
                        .onSubmit { saveAIKey() }
                    Button("保存") { saveAIKey() }
                        .disabled(aiKeyDraft == aiKeySaved)
                }
                let presetModels = AIProvider.find(aiProviderID)?.models ?? []
                let options = fetchedModels.isEmpty ? presetModels : fetchedModels
                if !options.isEmpty {
                    Picker("模型", selection: modelSelection) {
                        ForEach(options, id: \.self) { model in
                            Text(verbatim: model).tag(model)
                        }
                        Divider()
                        Text("自定义…").tag(AIProvider.customModelTag)
                    }
                    if aiModelIsCustom {
                        TextField("模型名", text: $aiModel, prompt: Text(verbatim: AISettings.defaultModel))
                    }
                } else {
                    TextField("模型", text: $aiModel, prompt: Text(verbatim: AISettings.defaultModel))
                }
                fetchModelRow

                TextField("API 地址", text: $aiBaseURL, prompt: Text(verbatim: AISettings.defaultBaseURL))
                Picker("接口格式", selection: $aiFormat) {
                    ForEach(AISettings.APIFormat.allCases) { format in
                        Text(format.label).tag(format.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("自动执行 AI 建议的命令", isOn: $aiAutoRun)
                Picker("单次对话命令轮数上限", selection: $aiMaxRounds) {
                    Text("12 轮(保守)").tag(12)
                    Text("30 轮(默认)").tag(30)
                    Text("60 轮").tag(60)
                    Text("100 轮").tag(100)
                }
                Text("每发一条消息,AI 最多连续执行这么多轮命令;达到上限会暂停,回复任意内容可继续。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("模型需支持工具调用(function calling),否则 AI 无法在服务器上执行命令。Key 只存钥匙串(随 iCloud 钥匙串同步),本地模型(Ollama / LM Studio)可留空。地址末尾已是版本号(如 /v1、/api/paas/v4)就按原样用,否则自动补 /v1。中转网关若提示不允许 /v1/messages,把接口格式切到「OpenAI 兼容」。开启自动执行后,危险命令与生产警戒主机仍会要求确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let provider = AIProvider.find(aiProviderID), let url = URL(string: provider.docsURL) {
                    Link("\(provider.name) 文档与模型列表", destination: url)
                        .font(.caption)
                }
                if let aiKeyNote {
                    Text(aiKeyNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                aiKeySaved = (try? KeychainStore.read(account: AISettings.apiKeyAccount)) ?? ""
                aiKeyDraft = aiKeySaved
                aiProviderID = AIProvider.matching(baseURL: aiBaseURL)?.id ?? AIProvider.customID
                syncCustomModelFlag()
                // 已拉过该接入点的模型列表则静默续用(未拉过不打接口,等用户点按钮)
                if AISettings.isConfigured, let key = modelKey, modelCatalog.hasCache(for: key) {
                    fetchModelList(force: false)
                }
            }
            // 接口列表拉到/刷新后重新判定:当前模型不在列表里就停在「自定义…」,
            // 否则 Picker 没有匹配 tag 会显示成空白
            .onChange(of: fetchedModels) { _, _ in syncCustomModelFlag() }
            Section("自定义引导") {
                TextField(
                    "全局引导",
                    text: $aiCustomInstructions,
                    prompt: Text("对所有主机生效,例如:\n回复一律用中文\n改配置文件前先备份原文件").foregroundStyle(.quaternary),
                    axis: .vertical
                )
                .lineLimit(3...8)
                Text("注入每次 AI 对话的系统提示词,像 Codex 的 AGENTS.md。主机编辑器里可再写只对单台主机生效的引导,两者叠加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var securityPage: some View {
            Section {
                Toggle("使用私钥连接前要求 Touch ID / 密码验证", isOn: $requireTouchID)
                Text("同一主机本次运行内验证一次即可;空闲 15 分钟或更换密钥、跳板机后再次验证。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("粘贴保护:多行或危险命令先确认", isOn: $pasteProtection)
            }
    }

    @ViewBuilder
    private var dataPage: some View {
            Section("iCloud 同步") {
                HStack {
                    Text("状态")
                    Spacer()
                    if syncMonitor.phase == .syncing {
                        ProgressView().controlSize(.small)
                        Text("同步中…").foregroundStyle(.secondary)
                    } else {
                        Text(syncStatusLabel).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("上次同步")
                    Spacer()
                    Text(lastSyncLabel).foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即同步") { syncNow() }
                    if let syncNote {
                        Text(syncNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("主机、分组、端口转发、片段、模板与触发器经 iCloud 私有库自动同步;密码与私钥只在本机钥匙串,永不上传。「立即同步」推送本地改动;云端改动由系统自动拉取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task { await refreshSyncStatus() }
            Section("数据") {
                HStack {
                    Button("导出备份…") { exportBackup() }
                    Button("导入备份…") { importBackup() }
                }
                Text("备份为 JSON,只含托管主机/分组/转发/代理结构;密码、passphrase、私钥在 Keychain,不会导出。来自 ~/.ssh/config 的只读主机由本机配置文件管理,不会包含在备份中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dataMessage {
                    Text(dataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("ssh_config") {
                HStack {
                    Text(configImportSummary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("管理…") { isShowingConfigImport = true }
                }
                Text("选择 ~/.ssh/config 里哪些主机显示在侧栏。Berth 只读这个文件,不会修改它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var generalPage: some View {
            Section("通用") {
                Toggle("在菜单栏显示图标(会话切换 / 快速连接)", isOn: $menuBarExtraEnabled)
                Toggle("探测主机是否在线(侧栏状态条着色)", isOn: $probeReachability)
                    .onChange(of: probeReachability) { _, _ in HostReachability.shared.settingsChanged() }
                Text("每 30 秒对直连主机做一次 TCP 测活;跳板机/代理主机不探测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Toggle("自动检查更新", isOn: $autoCheckUpdates)
                updateRow
                LabeledContent("第三方开源库") {
                    Button("查看协议…") { showAcknowledgements = true }
                }
            }
    }

    /// 更新行:发现新版给「获取/跳过」,否则给手动检查按钮与结果
    @ViewBuilder
    private var updateRow: some View {
        let checker = UpdateChecker.shared
        if let update = checker.available {
            LabeledContent(String(localized: "新版本 \(update.version)")) {
                HStack(spacing: 8) {
                    if UpdateChecker.installedViaHomebrew {
                        Button("复制 brew 升级命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(UpdateChecker.brewUpgradeCommand, forType: .string)
                        }
                        .help(UpdateChecker.brewUpgradeCommand)
                    }
                    Button("打开下载页") { checker.openReleasePage(update) }
                    Button("跳过此版本") { checker.skip(update) }
                }
            }
        } else {
            LabeledContent("更新") {
                HStack(spacing: 8) {
                    if let result = checker.manualResult {
                        Text(result).foregroundStyle(.secondary)
                    }
                    if checker.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Button("检查更新") {
                        Task { await UpdateChecker.shared.check(manual: true) }
                    }
                    .disabled(checker.isChecking)
                }
            }
        }
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

    private var lastSyncLabel: String {
        guard let date = syncMonitor.lastSyncDate else { return String(localized: "尚无记录") }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// 模型下拉:落在预设列表里就选中它,否则选「自定义…」并显示输入框
    private var modelSelection: Binding<String> {
        Binding(
            get: { aiModelIsCustom ? AIProvider.customModelTag : aiModel },
            set: { selected in
                if selected == AIProvider.customModelTag {
                    aiModelIsCustom = true
                } else {
                    aiModelIsCustom = false
                    aiModel = selected
                }
            }
        )
    }

    /// 「获取/刷新模型列表」行:任何供应商(含自定义地址、本地端点)都显示。
    /// 拉到后模型选择器用接口列表;失败原因显示在这一行下方。
    private var fetchModelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    fetchModelList(force: true)
                } label: {
                    if modelCatalog.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            fetchedModels.isEmpty
                                ? String(localized: "获取模型列表")
                                : String(localized: "刷新模型列表"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
                .disabled(modelCatalog.isLoading || modelKey == nil)
                if let key = modelKey, modelCatalog.hasCache(for: key) {
                    Text("已获取 \(fetchedModels.count) 个模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error = modelCatalog.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(modelCatalog.errorIsNotice ? Color.secondary : Color.orange)
            }
        }
    }

    /// 已存的模型不在可选列表(接口拉到的优先,否则供应商常见列表)里 → 停在「自定义…」
    /// 并显示输入框,别把用户填的值顶掉
    private func syncCustomModelFlag() {
        let preset = AIProvider.find(aiProviderID)?.models ?? []
        let options = fetchedModels.isEmpty ? preset : fetchedModels
        aiModelIsCustom = !options.isEmpty && !options.contains(aiModel)
    }

    /// 选中供应商预设:填好地址、接口格式与常见模型(之后可手改)
    private func applyProvider(_ id: String) {
        guard let provider = AIProvider.find(id) else { return }
        aiBaseURL = provider.baseURL
        aiFormat = provider.format.rawValue
        aiModel = provider.defaultModel
        aiModelIsCustom = false
        AISettingsStore.shared.refresh()
    }

    /// 当前接口对应的模型目录缓存键(地址或格式还没填成形时为 nil)
    private var modelKey: AIModelCatalog.ConfigKey? {
        let baseURL = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: baseURL), url.scheme != nil,
              let format = AISettings.APIFormat(rawValue: aiFormat) else { return nil }
        return AIModelCatalog.key(baseURL: baseURL, format: format)
    }

    /// 已拉取的模型列表(按当前接入点持久化缓存,重启后仍在)
    private var fetchedModels: [String] {
        guard let key = modelKey else { return [] }
        return modelCatalog.models(for: key)
    }

    /// 拉取模型列表(需要 Key,本地端点免);成功且当前模型为手填时不用回默认,
    /// 让用户自己决定;失败缘由展示在按钮下方
    private func fetchModelList(force: Bool) {
        let key = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = AISettings.APIFormat(rawValue: aiFormat) ?? .anthropic
        let apiKey = AISettings.apiKey ?? ""
        let isLocal = URL(string: key).flatMap(\.host).map { ["localhost", "127.0.0.1", "::1"].contains($0.lowercased()) } ?? false
        // 远端接口没有 Key 必然 401,直接提示而不发请求
        guard !apiKey.isEmpty || isLocal else {
            modelCatalog.setError(String(localized: "请先保存 API Key 再获取模型列表。"))
            return
        }
        Task {
            await modelCatalog.load(baseURL: key, format: format, apiKey: apiKey, force: force)
        }
    }


    /// API Key 保存/清空(只进钥匙串)
    private func saveAIKey() {
        let trimmed = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try KeychainStore.delete(account: AISettings.apiKeyAccount)
                aiKeyNote = String(localized: "已清除 API Key")
            } else {
                try KeychainStore.save(trimmed, account: AISettings.apiKeyAccount)
                aiKeyNote = String(localized: "API Key 已保存到钥匙串")
            }
            aiKeySaved = trimmed
            aiKeyDraft = trimmed
            // AI 面板在另一个窗口,靠这个可观察状态即时切换到可用态
            AISettingsStore.shared.refresh()
        } catch {
            aiKeyNote = String(localized: "保存失败:\(error.localizedDescription)")
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            aiKeyNote = nil
        }
    }

    private func refreshSyncStatus() async {
        let container = CKContainer(identifier: "iCloud.com.berthssh.app")
        syncAccountStatus = (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    /// 推送本地待同步改动(flush 到 CloudKit 导出队列)并刷新账号状态,给出即时反馈
    private func syncNow() {
        let hadChanges = modelContext.hasChanges
        try? modelContext.save()
        Task { await refreshSyncStatus() }
        syncNote = hadChanges ? String(localized: "已推送本地改动") : String(localized: "本地无待同步改动")
        Task {
            try? await Task.sleep(for: .seconds(3))
            syncNote = nil
        }
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

/// 设置左栏分类
enum SettingsTab: String, CaseIterable, Identifiable {
    case terminal, session, ai, security, data, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return String(localized: "终端")
        case .session: return String(localized: "会话")
        case .ai: return String(localized: "AI 助手")
        case .security: return String(localized: "安全")
        case .data: return String(localized: "同步与数据")
        case .general: return String(localized: "通用")
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .session: return "rectangle.stack"
        case .ai: return "sparkles"
        case .security: return "lock.shield"
        case .data: return "icloud"
        case .general: return "gearshape"
        }
    }
}

/// 设置左栏的一行:圆角底色里的大图标 + 文字
private struct SettingsTabRow: View {
    let item: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : theme.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? theme.accentColor : theme.accentSoft)
                    )
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? theme.accentSoft : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
