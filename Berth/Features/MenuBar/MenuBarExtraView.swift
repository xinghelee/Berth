import AppKit
import SwiftData
import SwiftUI

/// 菜单栏常驻入口:活跃会话一键切换 + 最近主机快速连接。
/// 可在设置里关闭(SettingsKeys.menuBarExtra)。
struct MenuBarExtraView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Query(sort: \Host.sortOrder) private var hosts: [Host]

    var body: some View {
        if !sessionManager.sessions.isEmpty {
            Section(String(localized: "活跃会话")) {
                ForEach(sessionManager.sessions, id: \.id) { session in
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        sessionManager.focusPane(session.id)
                    } label: {
                        // 菜单会把模板符号强制单色,彩色状态点用 emoji
                        Text("\(stateDot(session)) \(session.spec.label)")
                    }
                }
            }
            Divider()
        }
        Section(String(localized: "快速连接")) {
            ForEach(recentHosts.prefix(8)) { host in
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    connect(host)
                } label: {
                    Label(host.label, systemImage: "bolt")
                }
            }
        }
        Divider()
        Button(String(localized: "打开 Berth")) {
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(String(localized: "退出 Berth")) {
            NSApp.terminate(nil)
        }
    }

    /// 最近连接优先,未连过的按列表顺序排在后面
    private var recentHosts: [Host] {
        hosts.sorted {
            switch ($0.lastConnectedAt, $1.lastConnectedAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.sortOrder < $1.sortOrder
            }
        }
    }

    private func stateDot(_ session: TerminalSession) -> String {
        switch session.state {
        case .connected: return "🟢"
        case .connecting: return "🟡"
        case .idle, .disconnected: return "⚪️"
        }
    }

    private func connect(_ host: Host) {
        host.lastConnectedAt = Date()
        _ = SessionManager.shared.open(spec: HostSpec.resolve(host, in: hosts))
    }
}
