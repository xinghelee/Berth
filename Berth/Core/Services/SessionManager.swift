import Foundation
import Observation
import SwiftData

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
        guard let hosts = try? context.fetch(FetchDescriptor<Host>()), !hosts.isEmpty else { return }
        for idString in ids {
            guard let uuid = UUID(uuidString: idString),
                  let host = hosts.first(where: { $0.id == uuid }) else { continue }
            open(spec: HostSpec.resolve(host, in: hosts))
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
