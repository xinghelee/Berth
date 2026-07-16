import Foundation
import Observation
import SwiftData

/// 全局活跃会话管理:持有所有 TerminalSession,标签页 UI 与快捷键都通过它操作。
/// 关闭窗口不等于断开连接 —— 会话生命周期跟随本对象(App 级单例),不跟随视图。
@MainActor
@Observable
final class SessionManager {
    static let shared = SessionManager()

    enum SplitAxis { case horizontal, vertical }

    private(set) var sessions: [TerminalSession] = []
    var selectedID: TerminalSession.ID?
    /// 有活跃连接的标签页请求关闭时置此值,UI 弹确认框
    var pendingCloseSession: TerminalSession?
    /// ⌘F:请求在当前会话打开搜索条(UI 消费后自增以触发)
    var searchRequestToken = 0
    /// 右侧服务器信息 inspector 是否可见
    var isInspectorVisible = false
    /// 右侧 SFTP 文件面板是否可见
    var isSFTPVisible = false
    /// 分屏归属:创建分屏时的选中会话(主面板)。仅当再次选中主面板时渲染分屏,
    /// 切到其他标签不再把分屏 pane 拼到别的主机旁边。
    var splitPrimaryID: TerminalSession.ID?
    /// 分屏副会话。不变量:splitSecondaryID != selectedID(否则同一会话渲染两份,
    /// 共享的 TerminalView NSView 会被后挂载方抢走父视图,一侧黑屏)
    var splitSecondaryID: TerminalSession.ID?
    var splitAxis: SplitAxis = .horizontal

    var splitSecondary: TerminalSession? {
        sessions.first { $0.id == splitSecondaryID }
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    /// 某台主机当前的连接态(供主机列表状态点用):任一会话已连=connected,
    /// 有会话在连=connecting,否则 none。
    enum HostLiveState { case connected, connecting, none }

    func liveState(for hostID: UUID) -> HostLiveState {
        var connecting = false
        for session in sessions where session.spec.hostID == hostID {
            if case .connected = session.state { return .connected }
            if case .connecting = session.state { connecting = true }
        }
        return connecting ? .connecting : .none
    }

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
        sessions.append(session)
        selectedID = session.id
        session.connect()
        persistOpenTabs()
        return session
    }

    // MARK: - 会话恢复(启动时重开上次的标签页)

    private static let openTabsKey = "session.openTabs"

    /// 打开的标签页(排除分屏副会话)按顺序持久化主机 ID
    private func persistOpenTabs() {
        let ids = sessions
            .filter { $0.id != splitSecondaryID }
            .map { $0.spec.hostID.uuidString }
        UserDefaults.standard.set(ids, forKey: Self.openTabsKey)
    }

    /// 启动时恢复上次的标签页:按保存顺序错峰自动连接(400ms 间隔,避免连接风暴)
    func restoreSessions(container: ModelContainer) async {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.restoreSessions) as? Bool ?? true
        guard enabled, sessions.isEmpty,
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

    /// ⌘T:以当前标签页的主机再开一个终端。复用当前连接(在其上开新 PTY 通道),不新建 TCP。
    func duplicateCurrent() {
        guard let current = selected else { return }
        open(
            spec: current.spec,
            transientPassword: current.transientPassword,
            transientPassphrase: current.transientPassphrase,
            reusing: current.liveConnection
        )
    }

    /// ⌘W:活跃会话需确认,其余直接关
    func requestClose(_ session: TerminalSession) {
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        if case .connected = session.state, needsConfirm {
            pendingCloseSession = session
        } else {
            close(session)
        }
    }

    func requestCloseCurrent() {
        guard let current = selected else { return }
        requestClose(current)
    }

    func close(_ session: TerminalSession) {
        session.shutdown()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        // 分屏任一端被关 → 解除分屏(另一端保留为普通标签)
        if splitSecondaryID == session.id || splitPrimaryID == session.id {
            splitPrimaryID = nil
            splitSecondaryID = nil
        }
        if selectedID == session.id {
            let fallback = min(index, sessions.count - 1)
            selectedID = fallback >= 0 ? sessions[fallback].id : nil
            // fallback 可能落在分屏副会话上,维持互斥不变量
            if selectedID == splitSecondaryID {
                splitPrimaryID = nil
                splitSecondaryID = nil
            }
        }
        // 最后一个标签关掉后,面板开关复位,避免下次新建连接时面板凭空弹出
        if sessions.isEmpty {
            isSFTPVisible = false
            isInspectorVisible = false
        }
        persistOpenTabs()
    }

    /// 统一选中入口(标签 chip / ⌘1-9 都走这里):
    /// 选中分屏副会话本身时先解除分屏(副会话晋升为普通标签),避免同一会话渲染两份
    func select(id: TerminalSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let switchedHost = selectedID != id
        if id == splitSecondaryID {
            splitPrimaryID = nil
            splitSecondaryID = nil
        }
        selectedID = id
        // 切换到别的主机时收起右侧面板,避免残留上一台主机的 SFTP/信息数据
        if switchedHost {
            isSFTPVisible = false
            isInspectorVisible = false
        }
    }

    /// ⌘1-9
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(id: sessions[index].id)
    }

    func requestSearch() {
        guard selected != nil else { return }
        searchRequestToken += 1
    }

    // MARK: - 分屏(⌘D / ⌘⇧D)

    /// 当前标签已有分屏则关闭(连副会话一起关);否则用当前主机再开一个会话并排显示。
    /// 其他标签开着的分屏会先解除(其副会话保留为普通标签,不误杀)。
    func toggleSplit(axis: SplitAxis) {
        guard let current = selected else { return }
        if splitPrimaryID == current.id, let secondary = splitSecondary {
            close(secondary) // close 内部会清 split 标记
            return
        }
        splitPrimaryID = nil
        splitSecondaryID = nil
        splitAxis = axis
        let secondary = TerminalSession(spec: current.spec)
        secondary.transientPassword = current.transientPassword
        secondary.transientPassphrase = current.transientPassphrase
        // 分屏复用当前连接:在同一 SSH 连接上开第二个 PTY,不新建 TCP(避免触发频率惩罚)
        if let connection = current.liveConnection { secondary.prepareToBorrow(connection) }
        sessions.append(secondary)
        splitPrimaryID = current.id
        splitSecondaryID = secondary.id
        secondary.connect()
    }
}
