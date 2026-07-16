import Foundation
import Observation

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
    /// 分屏:与当前选中会话并排显示的第二个会话
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
    func open(spec: HostSpec, transientPassword: String? = nil, transientPassphrase: String? = nil) -> TerminalSession {
        let session = TerminalSession(spec: spec)
        session.transientPassword = transientPassword
        session.transientPassphrase = transientPassphrase
        sessions.append(session)
        selectedID = session.id
        session.connect()
        return session
    }

    /// ⌘T:以当前标签页的主机再开一个连接
    func duplicateCurrent() {
        guard let current = selected else { return }
        open(
            spec: current.spec,
            transientPassword: current.transientPassword,
            transientPassphrase: current.transientPassphrase
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
        if splitSecondaryID == session.id { splitSecondaryID = nil }
        if selectedID == session.id {
            let fallback = min(index, sessions.count - 1)
            selectedID = fallback >= 0 ? sessions[fallback].id : nil
        }
    }

    /// ⌘1-9
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    func requestSearch() {
        guard selected != nil else { return }
        searchRequestToken += 1
    }

    // MARK: - 分屏(⌘D / ⌘⇧D)

    /// 已分屏则取消;否则用当前主机再开一个会话并排显示
    func toggleSplit(axis: SplitAxis) {
        guard let current = selected else { return }
        if splitSecondaryID != nil {
            if let secondary = splitSecondary { close(secondary) }
            splitSecondaryID = nil
            return
        }
        splitAxis = axis
        let secondary = TerminalSession(spec: current.spec)
        secondary.transientPassword = current.transientPassword
        secondary.transientPassphrase = current.transientPassphrase
        sessions.append(secondary)
        splitSecondaryID = secondary.id
        secondary.connect()
    }
}
