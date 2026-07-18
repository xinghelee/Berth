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
    var selectedTabID: PaneTab.ID?

    /// 有活跃连接的 pane 请求关闭时置此值,UI 弹确认框
    var pendingCloseSession: TerminalSession?
    /// 含活跃连接的标签整体请求关闭
    var pendingCloseTab: PaneTab?
    /// ⌘F:请求在当前会话打开搜索条(UI 消费后自增以触发)
    var searchRequestToken = 0
    var isInspectorVisible = false
    var isSFTPVisible = false
    var isSnippetsPanelVisible = false

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

    @discardableResult
    func open(
        spec: HostSpec,
        transientPassword: String? = nil,
        transientPassphrase: String? = nil,
        reusing connection: SSHConnection? = nil
    ) -> TerminalSession {
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
        session.connect()
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
        guard let tab = selectedTab, let current = selected else { return }
        let secondary = TerminalSession(spec: current.spec)
        secondary.transientPassword = current.transientPassword
        secondary.transientPassphrase = current.transientPassphrase
        if let connection = current.liveConnection { secondary.prepareToBorrow(connection) }
        secondary.onShellExit = { [weak self, weak secondary] in
            guard let self, let secondary else { return }
            self.closePane(secondary)
        }
        sessions.append(secondary)
        tab.root = tab.root.splitting(leaf: current.id, into: secondary.id, axis: axis, branchID: UUID())
        tab.focusedID = secondary.id
        secondary.connect()
    }

    /// 点击某个 pane 聚焦它(可能在别的标签)
    func focusPane(_ sessionID: UUID) {
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(sessionID) }) else { return }
        let switchedTab = selectedTabID != tab.id
        selectedTabID = tab.id
        tab.focusedID = sessionID
        if switchedTab {
            isSFTPVisible = false
            isInspectorVisible = false
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
        sessions.removeAll { $0.id == session.id }
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(session.id) }) else {
            afterClose(); return
        }
        let neighbor = tab.root.neighborLeaf(of: session.id)
        if let newRoot = tab.root.removing(leaf: session.id) {
            tab.root = newRoot
            if tab.focusedID == session.id { tab.focusedID = neighbor ?? newRoot.firstLeaf }
        } else {
            tabs.removeAll { $0.id == tab.id }
            if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
        }
        afterClose()
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
            sessions.removeAll { $0.id == id }
        }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
        afterClose()
    }

    private func afterClose() {
        if tabs.isEmpty {
            isSFTPVisible = false
            isInspectorVisible = false
        }
        persistOpenTabs()
    }

    // MARK: - 选择

    /// 标签 chip / ⌘1-9:选中某标签(聚焦其上次的 pane)
    func selectTab(_ id: PaneTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let switched = selectedTabID != id
        selectedTabID = id
        if switched {
            isSFTPVisible = false
            isInspectorVisible = false
        }
        _ = tab
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
        case .branch(_, let axis, let a, let b):
            switch (encodeNode(a), encodeNode(b)) {
            case (nil, nil): return nil
            case (let x?, nil), (nil, let x?): return x
            case (let x?, let y?): return .split(axis: axis == .horizontal ? "h" : "v", first: x, second: y)
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
    }

    private func firstResolvableHost(_ node: WorkspaceLayout.Node, hosts: [Host]) -> Host? {
        switch node {
        case .leaf(let hostID):
            return hosts.first { $0.id == hostID }
        case .split(_, let a, let b):
            return firstResolvableHost(a, hosts: hosts) ?? firstResolvableHost(b, hosts: hosts)
        }
    }

    /// 递归补分屏:existingLeaf 代表 node 的 first-leaf 位置已存在的会话
    private func buildSplits(_ node: WorkspaceLayout.Node, existingLeaf: UUID, in tab: PaneTab, hosts: [Host]) {
        guard case .split(let axisRaw, let a, let b) = node else { return }
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
        tab.root = tab.root.splitting(leaf: existingLeaf, into: secondary.id, axis: axis, branchID: UUID())
        secondary.connect()
        buildSplits(a, existingLeaf: existingLeaf, in: tab, hosts: hosts)
        buildSplits(b, existingLeaf: secondary.id, in: tab, hosts: hosts)
    }

    // MARK: - 会话恢复

    private static let openTabsKey = "session.openTabs"

    /// 每个标签持久化其首个 pane 的主机 id(嵌套布局不恢复)
    private func persistOpenTabs() {
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
        guard !hosts.isEmpty else { return }
        for idString in ids {
            guard let uuid = UUID(uuidString: idString),
                  let host = hosts.first(where: { $0.id == uuid }) else { continue }
            open(spec: HostSpec.resolve(host, in: hosts))
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
