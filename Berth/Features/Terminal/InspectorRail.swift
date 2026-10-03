import SwiftUI

/// 右侧检查器栏(Xcode inspector 式):标题栏一个开关整体展开/收起,
/// 栏内顶部一排图标标签选面板(AI / SFTP / 信息 / Docker / 片段),互斥单开。
/// 本地 Shell 会话只露 AI 与片段;SSH 专属面板的选中态在切回 SSH 标签后自动恢复。
struct InspectorRail: View {
    let session: TerminalSession
    var width: CGFloat = InspectorRail.defaultWidth
    @Environment(SessionManager.self) private var sessionManager

    static let defaultWidth: CGFloat = 320
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 900

    @Namespace private var segmentNamespace

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private struct RailTab: Identifiable {
        let panel: SessionManager.SidePanel
        let symbol: String
        let help: String
        /// SSH 专属面板在本地 Shell 会话上置灰(不隐藏 —— 图标条保持完整,含义稳定)
        var sshOnly = false
        var id: String { panel.rawValue }
    }

    private var tabs: [RailTab] {
        [
            RailTab(panel: .ai, symbol: "sparkles", help: String(localized: "AI 助手(⌘⇧A)")),
            RailTab(panel: .sftp, symbol: "folder", help: String(localized: "SFTP 文件(⌘⇧F)"), sshOnly: true),
            RailTab(panel: .info, symbol: "info.circle", help: String(localized: "服务器信息(⌘I)"), sshOnly: true),
            RailTab(panel: .docker, symbol: "shippingbox", help: String(localized: "Docker 状态"), sshOnly: true),
            RailTab(panel: .snippets, symbol: "curlybraces", help: String(localized: "命令片段(⌘⇧S)")),
        ]
    }

    private func isAvailable(_ tab: RailTab) -> Bool {
        !(tab.sshOnly && session.spec.isLocal)
    }

    /// 本地会话上选中了 SSH 专属面板时临时落回 AI(不改状态,切回 SSH 标签自动恢复)
    private var effectivePanel: SessionManager.SidePanel {
        guard let active = sessionManager.activeSidePanel else { return .ai }
        return tabs.contains { $0.panel == active && isAvailable($0) } ? active : .ai
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.borderColor)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .background(theme.panelBackground)
    }

    /// Xcode 26 式分段胶囊:整条是一个胶囊容器,选中段是浮起小胶囊(切换时滑动跟随)。
    /// 收起不在这里 —— 走标题栏开关(与 Xcode 一致)
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                railTabButton(tab)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(theme.elevatedBackground)
                .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func railTabButton(_ tab: RailTab) -> some View {
        let isActive = effectivePanel == tab.panel
        let available = isAvailable(tab)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                sessionManager.activeSidePanel = tab.panel
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(available ? (isActive ? Color.primary : Color.secondary) : Color.secondary.opacity(0.35))
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    // 选中段 = 液态玻璃小胶囊(26+ glassEffect;15 退化为浮起材质)
                    if isActive, available {
                        RaisedCapsule()
                            .matchedGeometryEffect(id: "rail-segment", in: segmentNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(available ? tab.help : tab.help + String(localized: "(仅 SSH 会话可用)"))
    }

    @ViewBuilder
    private var content: some View {
        switch effectivePanel {
        case .ai:
            AIChatPanelView(session: session) { close() }
                .id(session.id)
        case .sftp:
            SFTPPanelView(session: session) { close() }
                .id(session.id)
        case .info:
            ServerInfoInspector(session: session) { close() }
        case .docker:
            DockerPanelView(session: session) { close() }
                .id(session.id)
        case .snippets:
            SnippetsPanelView { close() }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sessionManager.activeSidePanel = nil
        }
    }
}
