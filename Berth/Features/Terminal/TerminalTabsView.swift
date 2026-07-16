import SwiftUI

/// 右侧终端区:标签条 + 当前会话终端 + 断线横幅。
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            if sessionManager.tabs.isEmpty {
                emptyState
            } else if let tab = sessionManager.selectedTab {
                HStack(spacing: 0) {
                    // 单 pane 不显示焦点边框(只有分屏时才需要区分)
                    PaneTreeView(node: tab.root, focusedID: tab.focusedID, showsFocus: tab.root.leafIDs().count > 1) { id in
                        sessionManager.focusPane(id)
                    }
                    if let session = sessionManager.selected {
                        if sessionManager.isSFTPVisible {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            SFTPPanelView(session: session) {
                                sessionManager.isSFTPVisible = false
                            }
                            .id(session.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if sessionManager.isInspectorVisible {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            ServerInfoInspector(session: session) {
                                sessionManager.isInspectorVisible = false
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                if let session = sessionManager.selected {
                    StatusBarView(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
        // 顶部统一一行:标签 chips 靠左 | 会话胶囊居中 | 面板按钮组靠右(原独立标签条撤掉)。
        // chips 与按钮组自带胶囊样式,隐藏系统工具栏 item 的玻璃底避免双层;居中胶囊用系统底。
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    if !sessionManager.tabs.isEmpty { tabChips }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    if !sessionManager.tabs.isEmpty { tabChips }
                }
            }
            ToolbarItem(placement: .principal) {
                if let session = sessionManager.selected {
                    SessionTitleCapsule(session: session) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            sessionManager.isInspectorVisible.toggle()
                        }
                    }
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    if !sessionManager.tabs.isEmpty { panelButtons }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    if !sessionManager.tabs.isEmpty { panelButtons }
                }
            }
        }
        .alert(
            "关闭分屏「\(sessionManager.pendingCloseSession?.spec.label ?? "")」?",
            isPresented: Binding(
                get: { manager.pendingCloseSession != nil },
                set: { if !$0 { manager.pendingCloseSession = nil } }
            )
        ) {
            Button("断开并关闭", role: .destructive) {
                if let session = sessionManager.pendingCloseSession {
                    sessionManager.closePane(session)
                }
                manager.pendingCloseSession = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseSession = nil }
        } message: {
            Text("该分屏有活跃的 SSH 连接。")
        }
        .alert(
            "关闭标签页?",
            isPresented: Binding(
                get: { manager.pendingCloseTab != nil },
                set: { if !$0 { manager.pendingCloseTab = nil } }
            )
        ) {
            Button("断开并关闭", role: .destructive) {
                if let tab = sessionManager.pendingCloseTab {
                    sessionManager.closeTab(tab)
                }
                manager.pendingCloseTab = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseTab = nil }
        } message: {
            Text("该标签页含活跃的 SSH 连接(可能有多个分屏)。")
        }
    }

    /// 标签 chips(标题栏左侧):每个标签一枚 chip(含嵌套分屏);两端渐隐,选中自动滚入
    private var tabChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessionManager.tabs) { tab in
                        TerminalTabChip(
                            tab: tab,
                            focusedSession: sessionManager.session(tab.focusedID),
                            paneCount: tab.root.leafIDs().count,
                            isSelected: tab.id == sessionManager.selectedTabID,
                            select: { sessionManager.selectTab(tab.id) },
                            close: { sessionManager.requestCloseTab(tab) }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            )
            .onChange(of: sessionManager.selectedTabID) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// Safari 式按钮组(标题栏右侧):一个大胶囊容器,内含各个圆形悬停按钮
    private var panelButtons: some View {
        HStack(spacing: 2) {
            PanelIconButton(
                symbol: "folder",
                help: "SFTP 文件(⌘⇧F)",
                tint: sessionManager.isSFTPVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isSFTPVisible.toggle()
                }
            }
            PanelIconButton(
                symbol: "sidebar.right",
                help: "服务器信息(⌘I)",
                tint: sessionManager.isInspectorVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isInspectorVisible.toggle()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(ThemeStore.shared.current.elevatedBackground)
                .overlay(Capsule().stroke(ThemeStore.shared.current.borderColor, lineWidth: 1))
        )
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

/// 标题栏中央的会话信息胶囊(Safari 地址栏式):状态点 + 名称 + user@host,点按开合信息面板
private struct SessionTitleCapsule: View {
    let session: TerminalSession
    let action: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var stateColor: Color {
        switch session.state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected(let reason):
            return reason == .userInitiated ? .gray : .red
        }
    }

    private var address: String {
        let port = session.spec.port == 22 ? "" : ":\(session.spec.port)"
        return "\(session.spec.username)@\(session.spec.hostname)\(port)"
    }

    private var isProd: Bool { session.spec.isProduction }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isProd {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                } else {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                }
                Text(session.spec.label)
                    .font(.system(size: 12, weight: isProd ? .semibold : .medium))
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isProd ? Color.white.opacity(0.85) : Color.secondary)
            }
            .lineLimit(1)
            .foregroundStyle(isProd ? .white : .primary)
            .padding(.horizontal, isProd ? 12 : 6)
            .padding(.vertical, 3)
            // 生产环境:整颗胶囊染红警戒(其余情况沿用系统 principal 胶囊底)
            .background(
                Capsule().fill(isProd ? Color(red: 0.78, green: 0.13, blue: 0.13) : .clear)
            )
            .contentShape(Capsule())
            .opacity(hovering ? 1 : 0.9)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(isProd ? "⚠️ 生产环境:\(address)" : "当前会话:\(address) —— 点按查看服务器信息(⌘I)")
    }
}

/// 分屏树递归视图:叶子=一个终端 pane(可点按聚焦、聚焦有强调边框),分支=按方向二分
private struct PaneTreeView: View {
    let node: PaneNode
    let focusedID: UUID
    var showsFocus: Bool = true
    let onFocus: (UUID) -> Void
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        switch node {
        case .leaf(let sid):
            if let session = sessionManager.session(sid) {
                TerminalPaneView(session: session)
                    .id(sid)
                    .overlay(
                        Rectangle()
                            .stroke(
                                (showsFocus && sid == focusedID) ? ThemeStore.shared.current.accentColor.opacity(0.55) : .clear,
                                lineWidth: 1.5
                            )
                            .allowsHitTesting(false)
                    )
                    // 点非聚焦 pane 时先聚焦(不吞掉终端本身的交互)
                    .onTapGesture { if sid != focusedID { onFocus(sid) } }
            } else {
                Color.clear
            }
        case .branch(_, let axis, let first, let second):
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 1))
                : AnyLayout(VStackLayout(spacing: 1))
            layout {
                PaneTreeView(node: first, focusedID: focusedID, showsFocus: showsFocus, onFocus: onFocus)
                Rectangle()
                    .fill(ThemeStore.shared.current.borderColor)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                PaneTreeView(node: second, focusedID: focusedID, showsFocus: showsFocus, onFocus: onFocus)
            }
        }
    }
}

private struct TerminalTabChip: View {
    let tab: PaneTab
    let focusedSession: TerminalSession?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(focusedSession?.spec.label ?? "终端")
                .font(.system(size: 12))
                .lineLimit(1)
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("\(paneCount) 个分屏")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 0.7 : 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isSelected ? ThemeStore.shared.current.accentSoft : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? ThemeStore.shared.current.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }

    private var stateColor: Color {
        switch focusedSession?.state {
        case .idle, .none: return .gray
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
        VStack(spacing: 0) {
            hostStrip
            ZStack(alignment: .top) {
                TerminalHostView(terminalView: session.terminalView)
                    .padding(.leading, 8)
                    .padding(.top, 4)
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

    /// 非生产主机若设了标签色,顶部一条细色带区分环境(生产环境改由标题胶囊变红提示)
    @ViewBuilder
    private var hostStrip: some View {
        let tag = TagColor(rawValue: session.spec.tagColorRaw) ?? .none
        if !session.spec.isProduction, tag != .none {
            Rectangle()
                .fill(tag.color)
                .frame(height: 3)
                .frame(maxWidth: .infinity)
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
