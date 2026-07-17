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
                        // 菜单会把模板符号强制单色,自绘非模板圆点保留颜色且尺寸可控
                        Label {
                            Text(session.spec.label)
                        } icon: {
                            Image(nsImage: Self.dotImage(for: session))
                        }
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

    private static let greenDot = makeDot(.systemGreen)
    private static let yellowDot = makeDot(.systemYellow)
    private static let grayDot = makeDot(.tertiaryLabelColor)

    private static func dotImage(for session: TerminalSession) -> NSImage {
        switch session.state {
        case .connected: return greenDot
        case .connecting: return yellowDot
        case .idle, .disconnected: return grayDot
        }
    }

    /// 9pt 实心圆点,非模板图,菜单中保留颜色
    private static func makeDot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func connect(_ host: Host) {
        host.lastConnectedAt = Date()
        _ = SessionManager.shared.open(spec: HostSpec.resolve(host, in: hosts))
    }
}
