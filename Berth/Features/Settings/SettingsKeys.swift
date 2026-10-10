import Foundation

/// @AppStorage / UserDefaults 键名统一定义
enum SettingsKeys {
    static let terminalFontSize = "terminal.fontSize"
    /// 标题栏标签字号(issue #41:4K 原生分辨率下 12pt 太小);默认 12
    static let tabFontSize = "ui.tabFontSize"
    /// 终端字体族(空 = 系统等宽 SF Mono;选 Nerd 字体可显示私用区图标)
    static let terminalFontFamily = "terminal.fontFamily"
    static let confirmBeforeClosingTab = "terminal.confirmBeforeClosingTab"
    static let autoReconnect = "session.autoReconnect"
    static let terminalTheme = "terminal.theme"
    static let cursorShape = "terminal.cursorShape"
    static let cursorBlink = "terminal.cursorBlink"
    static let requireTouchIDForKeys = "security.requireTouchIDForKeys"
    static let pasteProtection = "terminal.pasteProtection"
    static let notifyLongCommand = "session.notifyLongCommand"
    static let restoreSessions = "session.restoreOnLaunch"
    static let copyOnSelect = "terminal.copyOnSelect"
    static let middleClickPaste = "terminal.middleClickPaste"
    static let restoreWorkingDir = "session.restoreWorkingDir"
    /// 界面语言:system / zh-Hans / en(写 AppleLanguages 覆盖,重启生效)
    static let appLanguage = "app.language"
    /// 菜单栏常驻图标
    static let menuBarExtra = "app.menuBarExtra"
    /// 侧栏主机可达性探测(TCP 测活,默认关)
    static let probeReachability = "app.probeReachability"
    /// 演示模式:主机列表隐藏真实主机,显示内置示例(录屏/截图防泄漏)
    static let demoMode = "app.demoMode"
    /// 隐私模式:界面上的主机地址/IP 打码,再点一下恢复(录屏用)
    static let privacyMode = "app.privacyMode"
    /// 透明毛玻璃 chrome:侧栏/标题栏透出桌面(终端区始终不透明)
    static let translucentChrome = "app.translucentChrome"
    /// AI 助手:模型名(空 = 默认 claude-opus-5)
    static let aiModel = "ai.model"
    /// AI 助手:API 地址(空 = https://api.anthropic.com;兼容自建中转)
    static let aiBaseURL = "ai.baseURL"
    /// AI 助手:自动执行 AI 建议的命令(危险命令与生产主机仍需确认,默认关)
    static let aiAutoRunCommands = "ai.autoRunCommands"
    /// AI 助手:请求格式(anthropic / openAI 兼容)
    static let aiAPIFormat = "ai.apiFormat"
    /// AI 助手:单次对话命令轮数上限(0/未设 = 默认 30)
    static let aiMaxCommandRounds = "ai.maxCommandRounds"
    /// AI 助手:全局自定义引导(注入系统提示词,对所有主机生效;按主机的在 Host.aiInstructions)
    static let aiCustomInstructions = "ai.customInstructions"
    /// 本地 Shell 路径(空 = 登录 shell;macOS 本地终端会话用)
    static let localShellPath = "terminal.localShellPath"
    /// SFTP 双击编辑远端文件时用的本地编辑器 .app 路径(空 = 纯文本类型按系统默认应用,其余纯文本编辑器,见 RemoteEditOpenPolicy)
    static let externalEditorPath = "sftp.externalEditorPath"
    /// 自动检查更新(GitHub Releases API,默认开)
    static let autoCheckUpdates = "app.autoCheckUpdates"
    /// 用户选择跳过的版本号(该版本不再提示,新版本会重新提示)
    static let skippedUpdateVersion = "app.skippedUpdateVersion"
    /// 仪表盘采集间隔(秒,默认 5)
    static let dashboardInterval = "dashboard.interval"
    /// 仪表盘排序方式(DashboardSort.rawValue)
    static let dashboardSort = "dashboard.sort"
    /// 仪表盘卡片显示比例(1 / 1.25 / 1.5),适合高分辨率大屏常驻查看
    static let dashboardCardScale = "dashboard.cardScale"
    /// 侧栏主机行双击 = 再开一条同主机连接(默认开;关掉则双击等同单击)
    static let doubleClickNewConnection = "sidebar.doubleClickNewConnection"
}
