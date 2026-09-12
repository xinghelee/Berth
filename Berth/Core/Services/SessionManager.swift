import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// 全局活跃会话管理:持有所有 TerminalSession(会话池)与标签页(每个标签是一棵可无限嵌套的分屏树)。
/// 关闭窗口不等于断开连接 —— 会话生命周期跟随本对象(App 级单例),不跟随视图。
@MainActor
@Observable
final class SessionManager {
    static let shared = SessionManager()

    /// 所有活跃会话(跨全部标签的池,供 liveState / 查找 / 连接复用)
    private(set) var sessions: [TerminalSession] = []
    /// 标签页(每个是一棵分屏树)
    private(set) var tabs: [PaneTab] = []
    var selectedTabID: PaneTab.ID? {
        didSet { syncSelectedHostID() }
    }
    /// 侧栏高亮与当前标签共享的主机选择。侧栏键盘导航也写回这里；
    /// 标签、分屏焦点变化则由 syncSelectedHostID() 覆盖成当前会话的主机。
    var selectedHostID: UUID?

    /// 有活跃连接的 pane 请求关闭时置此值,UI 弹确认框
    var pendingCloseSession: TerminalSession?
    /// 含活跃连接的标签整体请求关闭
    var pendingCloseTab: PaneTab?
    /// ⌘F:请求在当前会话打开搜索条(UI 消费后自增以触发)
    var searchRequestToken = 0
    /// ⌘0:终端区整体切成仪表盘(标签条留着,会话不受影响);独立窗口另有一份
    var isDashboardVisible = false

    /// 右侧检查器栏(Xcode inspector 式):同一时间只开一个面板,栏内图标条切换
    enum SidePanel: String {
        case ai, sftp, info, docker, snippets
    }
    var activeSidePanel: SidePanel? {
        didSet { if let panel = activeSidePanel { lastSidePanel = panel } }
    }
    /// 收起前最后停留的面板:标题栏单开关重新展开时回到它
    @ObservationIgnored private var lastSidePanel: SidePanel = .ai

    /// 标题栏开关:展开(回到上次面板)/ 收起整条检查器栏
    func toggleInspectorRail() {
        activeSidePanel = activeSidePanel == nil ? lastSidePanel : nil
    }

    // 旧的五个开关保留成兼容属性:置 true = 切到该面板(自动关别的),置 false = 收起
    var isInspectorVisible: Bool {
        get { activeSidePanel == .info }
        set { setPanel(.info, visible: newValue) }
    }
    var isSFTPVisible: Bool {
        get { activeSidePanel == .sftp }
        set { setPanel(.sftp, visible: newValue) }
    }
    var isSnippetsPanelVisible: Bool {
        get { activeSidePanel == .snippets }
        set { setPanel(.snippets, visible: newValue) }
    }
    var isAIPanelVisible: Bool {
        get { activeSidePanel == .ai }
        set { setPanel(.ai, visible: newValue) }
    }
    var isDockerPanelVisible: Bool {
        get { activeSidePanel == .docker }
        set { setPanel(.docker, visible: newValue) }
    }

    private func setPanel(_ panel: SidePanel, visible: Bool) {
        if visible {
            activeSidePanel = panel
        } else if activeSidePanel == panel {
            activeSidePanel = nil
        }
    }

    /// 由 App 启动时注入,用于连接后回写主机的探测信息(系统名等)
    @ObservationIgnored var modelContainer: ModelContainer?

    /// 连接成功后记录服务器系统名(侧栏徽章数据源)
    func recordServerOS(hostID: UUID, os: String) {
        guard !os.isEmpty, let modelContainer else { return }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.id == hostID })
        if let host = try? context.fetch(descriptor).first {
            if host.osName != os {
                host.osName = os
                try? context.save()
            }
        } else if let mirror = SSHConfigService.shared.mirrorHosts.first(where: { $0.id == hostID }) {
            // config 镜像是内存态,直接改实例(不落库)
            mirror.osName = os
        }
    }

    var selectedTab: PaneTab? { tabs.first { $0.id == selectedTabID } }

    /// 当前聚焦会话
    var selected: TerminalSession? {
        guard let focused = selectedTab?.focusedID else { return nil }
        return sessions.first { $0.id == focused }
    }

    private func syncSelectedHostID() {
        guard let selected, !selected.spec.isLocal else {
            selectedHostID = nil
            return
        }
        selectedHostID = selected.spec.hostID
    }

    /// 兼容旧调用:selectedID = 当前标签聚焦的会话 id
    var selectedID: TerminalSession.ID? {
        get { selectedTab?.focusedID }
        set { if let nv = newValue { focusPane(nv) } }
    }

    // MARK: - 连接态查询

    enum HostLiveState { case connected, connecting, none }

    func liveState(for hostID: UUID) -> HostLiveState {
        var connecting = false
        for session in sessions where session.spec.hostID == hostID {
            if case .connected = session.state { return .connected }
            if case .connecting = session.state { connecting = true }
        }
        return connecting ? .connecting : .none
    }

    func session(_ id: UUID) -> TerminalSession? { sessions.first { $0.id == id } }

    // MARK: - 打开 / 复制

    /// `autoConnect: false` 只建标签不拨号,由 pane 首次显示时补连(启动恢复用,
    /// 见 restoreSessions —— 一次性连一屏标签会让指纹确认弹窗和失败横幅一起涌上来)
    @discardableResult
    func open(
        spec: HostSpec,
        transientPassword: String? = nil,
        transientPassphrase: String? = nil,
        reusing connection: SSHConnection? = nil,
        autoConnect: Bool = true
    ) -> TerminalSession {
        // 新开会话 = 要看终端了,仪表盘让位
        isDashboardVisible = false
        let session = TerminalSession(spec: spec)
        session.transientPassword = transientPassword
        session.transientPassphrase = transientPassphrase
        if let connection { session.prepareToBorrow(connection) }
        session.onShellExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closePane(session)
        }
        sessions.append(session)
        let tab = PaneTab(sessionID: session.id)
        tabs.append(tab)
        selectedTabID = tab.id
        if autoConnect { session.connect() }
        persistOpenTabs()
        return session
    }

    /// ⌘T:以当前聚焦会话的主机再开一个标签。复用当前连接(同一 SSH 上开新 PTY),不新建 TCP。
    func duplicateCurrent() {
        guard let current = selected else { return }
        open(
            spec: current.spec,
            transientPassword: current.transientPassword,
            transientPassphrase: current.transientPassphrase,
            reusing: current.liveConnection
        )
    }

    // MARK: - 分屏(可无限嵌套)

    /// ⌘D / ⌘⇧D / 右键:在当前聚焦 pane 上再分出一个同主机会话(复用连接)。每次都新增,支持嵌套。
    func splitFocused(axis: SplitAxis) {
        guard let current = selected else { return }
        let secondary = TerminalSession(spec: current.spec)
        secondary.transientPassword = current.transientPassword
        secondary.transientPassphrase = current.transientPassphrase
        if let connection = current.liveConnection { secondary.prepareToBorrow(connection) }
        insertSplit(secondary, axis: axis)
    }

    /// 混合分屏:在当前聚焦 pane 旁分出一个本地 Shell(SSH 会话旁跑 scp/kubectl 等本地命令)
    func splitFocusedLocalShell(axis: SplitAxis) {
        guard selected != nil else { return }
        insertSplit(TerminalSession(spec: .localShell()), axis: axis)
    }

    /// issue #11:在当前聚焦 pane 旁分屏连接任意主机(右键/侧栏选主机)。
    /// 与聚焦会话同主机时仍复用其连接,行为与 splitFocused(axis:) 一致。
    func splitFocused(axis: SplitAxis, spec: HostSpec) {
        guard let current = selected else { return }
        let secondary = TerminalSession(spec: spec)
        if current.spec.hostID == spec.hostID {
            secondary.transientPassword = current.transientPassword
            secondary.transientPassphrase = current.transientPassphrase
            if let connection = current.liveConnection { secondary.prepareToBorrow(connection) }
        }
        insertSplit(secondary, axis: axis)
    }

    /// 全部可连主机(托管 + ssh_config 镜像),供 AppKit 菜单等 SwiftUI @Query 之外的场景
    func allKnownHosts() -> [Host] {
        let managed = (try? modelContainer?.mainContext.fetch(FetchDescriptor<Host>())) ?? []
        return managed + SSHConfigService.shared.mirrorHosts
    }

    /// 把新会话作为聚焦 pane 的兄弟插入分屏树并拨号
    private func insertSplit(_ secondary: TerminalSession, axis: SplitAxis) {
        guard let tab = selectedTab, let current = selected else { return }
        secondary.onShellExit = { [weak self, weak secondary] in
            guard let self, let secondary else { return }
            self.closePane(secondary)
        }
        sessions.append(secondary)
        tab.root = tab.root.splitting(leaf: current.id, into: secondary.id, axis: axis, branchID: UUID())
        tab.focusedID = secondary.id
        syncSelectedHostID()
        secondary.connect()
    }

    /// 点击某个 pane 聚焦它(可能在别的标签)
    func focusPane(_ sessionID: UUID) {
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(sessionID) }) else { return }
        // 主动去某个 pane = 要看终端,顺手从仪表盘退出来
        isDashboardVisible = false
        let switchedTab = selectedTabID != tab.id
        tab.focusedID = sessionID
        selectedTabID = tab.id
        syncSelectedHostID()
        if switchedTab {
            isSFTPVisible = false
            isInspectorVisible = false
        }
        refocusSelectedTerminal()
    }

    /// 切标签/关 pane 后把键盘焦点还给当前聚焦的终端(issue #9)。
    /// 非选中标签的终端视图不在窗口层级里,要等 SwiftUI 把新视图挂回窗口后
    /// makeFirstResponder 才有效,故延后一个 runloop。
    private func refocusSelectedTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.selected?.focusTerminal()
        }
    }

    // MARK: - 关闭

    /// ⌘W:关闭当前聚焦的 pane(活跃连接需确认)
    func requestCloseCurrent() {
        guard let session = selected else { return }
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        if case .connected = session.state, needsConfirm {
            pendingCloseSession = session
        } else {
            closePane(session)
        }
    }

    /// 兼容旧调用名
    func requestClose(_ session: TerminalSession) {
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        if case .connected = session.state, needsConfirm {
            pendingCloseSession = session
        } else {
            closePane(session)
        }
    }

    /// 关闭单个 pane:从其所在标签的树里移除并塌缩;标签空了则整标签移除
    func closePane(_ session: TerminalSession) {
        session.shutdown()
        AIChatStore.shared.remove(session.id)
        sessions.removeAll { $0.id == session.id }
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(session.id) }) else {
            afterClose(); return
        }
        let neighbor = tab.root.neighborLeaf(of: session.id)
        if let newRoot = tab.root.removing(leaf: session.id) {
            tab.root = newRoot
            if tab.focusedID == session.id { tab.focusedID = neighbor ?? newRoot.firstLeaf }
        } else {
            removeTabSelectingNeighbor(tab)
        }
        syncSelectedHostID()
        afterClose()
    }

    /// 移除标签并把选中交给位置邻居(原右邻顶上,没有则左邻)——
    /// 不再拿 tabs.last 兜底,关中间标签不会跳到最后一个
    private func removeTabSelectingNeighbor(_ tab: PaneTab) {
        let index = tabs.firstIndex { $0.id == tab.id }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            if let index, !tabs.isEmpty {
                selectedTabID = tabs[min(index, tabs.count - 1)].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
    }

    /// 整个标签关闭(标签 chip 的 ×):确认后连同其所有 pane 一起关
    func requestCloseTab(_ tab: PaneTab) {
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        let anyConnected = tab.root.leafIDs().contains { id in
            if case .connected = session(id)?.state { return true }
            return false
        }
        if anyConnected, needsConfirm {
            pendingCloseTab = tab
        } else {
            closeTab(tab)
        }
    }

    func closeTab(_ tab: PaneTab) {
        for id in tab.root.leafIDs() {
            if let s = session(id) { s.shutdown() }
            AIChatStore.shared.remove(id)
            sessions.removeAll { $0.id == id }
        }
        removeTabSelectingNeighbor(tab)
        afterClose()
    }

    private func afterClose() {
        if tabs.isEmpty {
            isSFTPVisible = false
            isInspectorVisible = false
            isAIPanelVisible = false
        }
        persistOpenTabs()
        refocusSelectedTerminal()
    }

    // MARK: - 选择

    /// 拖拽重排标签:把 id 标签移到 index 位置(顺序随 persistOpenTabs 持久化)
    func moveTab(_ id: PaneTab.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              from != index, index >= 0, index < tabs.count else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: index)
        persistOpenTabs()
    }

    /// 标签 chip / ⌘1-9:选中某标签(聚焦其上次的 pane)
    func selectTab(_ id: PaneTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        isDashboardVisible = false
        let switched = selectedTabID != id
        selectedTabID = id
        if switched {
            isSFTPVisible = false
            isInspectorVisible = false
        }
        _ = tab
        refocusSelectedTerminal()
    }

    /// 兼容旧调用:按会话 id 选中(聚焦其所在标签的该 pane)
    func select(id: TerminalSession.ID) { focusPane(id) }

    /// ⌘1-9
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func requestSearch() {
        guard selected != nil else { return }
        searchRequestToken += 1
    }

    /// 终端里选中的报错/输出丢给 AI 分析:打开面板并直接提问
    func askAIAboutSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = selected else { return }
        isAIPanelVisible = true
        AIChatStore.shared.controller(for: session).askAbout(trimmed)
    }

    /// 有选中内容时才给「询问 AI」的菜单/命令项亮起来
    var hasTerminalSelection: Bool {
        !(selected?.terminalView.getSelection() ?? "").isEmpty
    }

    /// 记录/停止记录当前会话到文件(记录时弹保存面板选路径)
    func toggleSessionLogging() {
        guard let session = selected else { return }
        if session.isLogging {
            session.stopLogging()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "\(session.spec.label)-\(stamp).log"
        panel.message = String(localized: "选择会话录制文件的保存位置")
        if panel.runModal() == .OK, let url = panel.url {
            session.startLogging(to: url)
        }
    }

    // MARK: - 广播输入

    /// 焦点 pane 的键入 → 同步到同标签其它 pane(仅广播开启时)
    func broadcastInput(from sessionID: UUID, bytes: [UInt8]) {
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(sessionID) }),
              tab.isBroadcasting else { return }
        for id in tab.root.leafIDs() where id != sessionID {
            session(id)?.sendRawInput(bytes)
        }
    }

    /// 切换当前标签的广播输入(需 ≥2 个 pane 才有意义)
    func toggleBroadcast() {
        guard let tab = selectedTab, tab.root.leafIDs().count > 1 else { return }
        tab.isBroadcasting.toggle()
    }

    var isBroadcasting: Bool { selectedTab?.isBroadcasting ?? false }

    // MARK: - 会话模板

    /// 捕获当前所有标签的布局(叶子 → 主机 id)
    func captureWorkspaceLayout() -> WorkspaceLayout {
        WorkspaceLayout(tabs: tabs.compactMap { encodeNode($0.root) })
    }

    private func encodeNode(_ node: PaneNode) -> WorkspaceLayout.Node? {
        switch node {
        case .leaf(let sessionID):
            guard let spec = session(sessionID)?.spec else { return nil }
            return .leaf(hostID: spec.hostID)
        case .branch(let branchID, let axis, let a, let b):
            switch (encodeNode(a), encodeNode(b)) {
            case (nil, nil): return nil
            case (let x?, nil), (nil, let x?): return x
            case (let x?, let y?):
                // 拖过的分割比例一并存(0.5 不存,省字段)
                let tab = tabs.first { $0.root.leafIDs().contains(node.firstLeaf) }
                let ratio = tab.map { $0.ratio(of: branchID) }
                return .split(
                    axis: axis == .horizontal ? "h" : "v",
                    ratio: ratio == 0.5 ? nil : ratio,
                    first: x,
                    second: y
                )
            }
        }
    }

    /// 打开模板:逐标签恢复分屏布局并连接;找不到的主机(已删除)跳过
    func openWorkspace(_ layout: WorkspaceLayout, hosts: [Host]) {
        for tabNode in layout.tabs {
            openWorkspaceTab(tabNode, hosts: hosts)
        }
    }

    private func openWorkspaceTab(_ node: WorkspaceLayout.Node, hosts: [Host]) {
        guard let firstHost = firstResolvableHost(node, hosts: hosts) else { return }
        firstHost.lastConnectedAt = Date()
        let first = open(spec: HostSpec.resolve(firstHost, in: hosts))
        guard let tab = tabs.last, tab.root.leafIDs() == [first.id] else { return }
        buildSplits(node, existingLeaf: first.id, in: tab, hosts: hosts)
        tab.focusedID = first.id
        syncSelectedHostID()
    }

    private func firstResolvableHost(_ node: WorkspaceLayout.Node, hosts: [Host]) -> Host? {
        switch node {
        case .leaf(let hostID):
            return hosts.first { $0.id == hostID }
        case .split(_, _, let a, let b):
            return firstResolvableHost(a, hosts: hosts) ?? firstResolvableHost(b, hosts: hosts)
        }
    }

    /// 递归补分屏:existingLeaf 代表 node 的 first-leaf 位置已存在的会话
    private func buildSplits(_ node: WorkspaceLayout.Node, existingLeaf: UUID, in tab: PaneTab, hosts: [Host]) {
        guard case .split(let axisRaw, let ratio, let a, let b) = node else { return }
        guard let bHost = firstResolvableHost(b, hosts: hosts) else {
            buildSplits(a, existingLeaf: existingLeaf, in: tab, hosts: hosts)
            return
        }
        guard firstResolvableHost(a, hosts: hosts) != nil else {
            // a 侧整体不可解析:b 顶替 existingLeaf 的位置继续
            buildSplits(b, existingLeaf: existingLeaf, in: tab, hosts: hosts)
            return
        }
        let axis: SplitAxis = axisRaw == "h" ? .horizontal : .vertical
        let secondary = TerminalSession(spec: HostSpec.resolve(bHost, in: hosts))
        secondary.onShellExit = { [weak self, weak secondary] in
            guard let self, let secondary else { return }
            self.closePane(secondary)
        }
        sessions.append(secondary)
        let branchID = UUID()
        tab.root = tab.root.splitting(leaf: existingLeaf, into: secondary.id, axis: axis, branchID: branchID)
        if let ratio { tab.setRatio(ratio, for: branchID) }
        secondary.connect()
        buildSplits(a, existingLeaf: existingLeaf, in: tab, hosts: hosts)
        buildSplits(b, existingLeaf: secondary.id, in: tab, hosts: hosts)
    }

    // MARK: - 会话恢复

    private static let openTabsKey = "session.openTabs"

    /// 每个标签持久化其首个 pane 的主机 id(嵌套布局不恢复)。
    /// 自动化验收(临时库)不写:UserDefaults 不随 BERTH_TRANSIENT_STORE 隔离,
    /// 验收结束关全部标签会把用户真实的恢复列表覆写成空
    private func persistOpenTabs() {
        guard ProcessInfo.processInfo.environment["BERTH_TRANSIENT_STORE"] != "1" else { return }
        let ids = tabs.compactMap { session($0.root.firstLeaf)?.spec.hostID.uuidString }
        UserDefaults.standard.set(ids, forKey: Self.openTabsKey)
    }

    func restoreSessions(container: ModelContainer) async {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.restoreSessions) as? Bool ?? true
        guard enabled, tabs.isEmpty,
              let ids = UserDefaults.standard.stringArray(forKey: Self.openTabsKey),
              !ids.isEmpty else { return }
        let context = ModelContext(container)
        let stored = (try? context.fetch(FetchDescriptor<Host>())) ?? []
        let hosts = stored + SSHConfigService.shared.mirrorHosts
        // 只有第一个标签自动拨号,其余等切过去再连:一次性把上次的标签全连起来,
        // 会让 known_hosts 指纹确认弹窗排队(后台标签的弹窗还压根显示不出来,
        // 会话就卡在「等待主机密钥确认」),连不上的主机也会一次涌出一片错误横幅。
        var isFirst = true
        for idString in ids {
            guard let uuid = UUID(uuidString: idString) else { continue }
            if uuid == HostSpec.localShellHostID {
                open(spec: .localShell(), autoConnect: isFirst)
                isFirst = false
                continue
            }
            guard let host = hosts.first(where: { $0.id == uuid }) else { continue }
            open(spec: HostSpec.resolve(host, in: hosts), autoConnect: isFirst)
            isFirst = false
        }
        selectedTabID = tabs.first?.id
    }
}
