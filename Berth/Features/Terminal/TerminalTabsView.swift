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
                if let session = sessionManager.selected {
                    if let secondary = sessionManager.splitSecondary {
                        splitContainer(primary: session, secondary: secondary)
                    } else {
                        TerminalPaneView(session: session)
                            .id(session.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
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
            .frame(height: AppLayout.topBarHeight)
        }
        .frame(height: AppLayout.topBarHeight)
        .padding(.top, AppLayout.columnTopPadding)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ThemeStore.shared.current.borderColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func splitContainer(primary: TerminalSession, secondary: TerminalSession) -> some View {
        let layout = sessionManager.splitAxis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 1))
            : AnyLayout(VStackLayout(spacing: 1))
        layout {
            TerminalPaneView(session: primary)
                .id(primary.id)
            Divider()
            TerminalPaneView(session: secondary)
                .id(secondary.id)
        }
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
                .fill(isSelected ? ThemeStore.shared.current.accentSoft : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? ThemeStore.shared.current.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
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

/// 单个会话面板:终端 + 顶部状态/断线横幅 + ⌘F 搜索 + 主机密钥确认
struct TerminalPaneView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    @State private var searchModel = TerminalSearchModel()
    @State private var isSearchActive = false

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(terminalView: session.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: ThemeStore.shared.current.backgroundNSColor))

            banner

            if isSearchActive {
                HStack {
                    Spacer()
                    TerminalSearchBar(model: searchModel) {
                        isSearchActive = false
                        searchModel.update(query: "")
                        session.focusTerminal()
                    }
                    .padding(.trailing, 12)
                }
            }
        }
        .onChange(of: sessionManager.searchRequestToken) { _, _ in
            // 只有当前选中会话响应 ⌘F
            guard session.id == sessionManager.selectedID else { return }
            searchModel.terminalView = session.terminalView
            isSearchActive = true
        }
        .sheet(
            item: $session.hostKeyPrompt,
            onDismiss: { session.resolveHostKeyPrompt(accepted: false) }
        ) { prompt in
            HostKeyPromptSheet(prompt: prompt, session: session)
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
                if session.isAutoReconnectScheduled {
                    Text("自动重连中(第 \(session.reconnectAttempt) 次)")
                        .foregroundStyle(.secondary)
                    Button("停止") { session.cancelAutoReconnect() }
                        .controlSize(.small)
                }
                Button("立即重连") { session.connect() }
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
