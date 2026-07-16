import SwiftUI

/// 右侧终端区:标签条 + 当前会话终端 + 断线横幅。
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            if sessionManager.sessions.isEmpty {
                emptyState
            } else {
                tabStrip
                Divider()
                if let session = sessionManager.selected {
                    TerminalPaneView(session: session)
                        .id(session.id)
                }
            }
        }
        .alert(
            "关闭标签页「\(sessionManager.pendingCloseSession?.spec.label ?? "")」?",
            isPresented: Binding(
                get: { manager.pendingCloseSession != nil },
                set: { if !$0 { manager.pendingCloseSession = nil } }
            )
        ) {
            Button("断开并关闭", role: .destructive) {
                if let session = sessionManager.pendingCloseSession {
                    sessionManager.close(session)
                }
                manager.pendingCloseSession = nil
            }
            Button("取消", role: .cancel) {
                manager.pendingCloseSession = nil
            }
        } message: {
            Text("该标签页有活跃的 SSH 连接。")
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sessionManager.sessions) { session in
                    TerminalTabChip(
                        session: session,
                        isSelected: session.id == sessionManager.selectedID,
                        select: { sessionManager.selectedID = session.id },
                        close: { sessionManager.requestClose(session) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("双击左侧主机开始连接")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalTabChip: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(session.spec.label)
                .font(.system(size: 12))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 0.7 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }

    private var stateColor: Color {
        switch session.state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected(let reason):
            return reason == .userInitiated ? .gray : .red
        }
    }
}

/// 单个会话面板:终端 + 顶部状态/断线横幅
struct TerminalPaneView: View {
    let session: TerminalSession

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(terminalView: session.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)))

            banner
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch session.state {
        case .connecting(let detail):
            bannerBody(color: .yellow) {
                ProgressView()
                    .controlSize(.mini)
                Text(detail)
            }
        case .disconnected(let reason):
            bannerBody(color: reason == .userInitiated ? .gray : .red) {
                Image(systemName: "bolt.slash")
                Text(reason.message ?? "连接已断开")
                    .lineLimit(2)
                Button("重连") { session.connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .idle, .connected:
            EmptyView()
        }
    }

    private func bannerBody(color: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        )
        .padding(.top, 8)
    }
}
