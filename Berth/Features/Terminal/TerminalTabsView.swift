import SwiftData
import SwiftUI

/// 右侧终端区:标签条 + 当前会话终端 + 断线横幅。
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            if sessionManager.tabs.isEmpty {
                emptyState
            } else if let tab = sessionManager.selectedTab {
                if tab.isBroadcasting {
                    broadcastBanner
                }
                HStack(spacing: 0) {
                    // 单 pane 不显示焦点边框(只有分屏时才需要区分)
                    PaneTreeView(
                        node: tab.root,
                        focusedID: tab.focusedID,
                        showsFocus: tab.root.leafIDs().count > 1,
                        broadcasting: tab.isBroadcasting
                    ) { id in
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
                        if sessionManager.isSnippetsPanelVisible {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            SnippetsPanelView {
                                sessionManager.isSnippetsPanelVisible = false
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
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    if let session = sessionManager.selected {
                        SessionTitleCapsule(session: session) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                sessionManager.isInspectorVisible.toggle()
                            }
                        }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    if let session = sessionManager.selected {
                        SessionTitleCapsule(session: session) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                sessionManager.isInspectorVisible.toggle()
                            }
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
                symbol: "curlybraces",
                help: String(localized: "命令片段(⌘⇧S)"),
                tint: sessionManager.isSnippetsPanelVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isSnippetsPanelVisible.toggle()
                }
            }
            PanelIconButton(
                symbol: "folder",
                help: String(localized: "SFTP 文件(⌘⇧F)"),
                tint: sessionManager.isSFTPVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isSFTPVisible.toggle()
                }
            }
            PanelIconButton(
                symbol: "sidebar.right",
                help: String(localized: "服务器信息(⌘I)"),
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

    /// 广播模式横幅:提示所有分屏同步接收键入
    private var broadcastBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10))
            Text("广播输入:键入同步到当前标签所有分屏")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button("停止") { sessionManager.toggleBroadcast() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.85))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            // 系统 principal 胶囊底已隐藏,这里自绘唯一一层:生产=红,否则=主题浮层色
            .background(
                Capsule()
                    .fill(isProd ? Color(red: 0.78, green: 0.13, blue: 0.13) : theme.elevatedBackground)
                    .overlay(
                        Capsule().stroke(
                            isProd ? .clear : (hovering ? theme.accentColor.opacity(0.4) : theme.borderColor),
                            lineWidth: 1
                        )
                    )
            )
            .contentShape(Capsule())
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
    var broadcasting: Bool = false
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
                            .stroke(borderColor(sid), lineWidth: broadcasting ? 1.5 : 1.5)
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
                PaneTreeView(node: first, focusedID: focusedID, showsFocus: showsFocus, broadcasting: broadcasting, onFocus: onFocus)
                Rectangle()
                    .fill(ThemeStore.shared.current.borderColor)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                PaneTreeView(node: second, focusedID: focusedID, showsFocus: showsFocus, broadcasting: broadcasting, onFocus: onFocus)
            }
        }
    }

    private func borderColor(_ sid: UUID) -> Color {
        // 广播时所有 pane 橙色边框;否则仅聚焦 pane 强调色边框
        if broadcasting { return .orange.opacity(0.7) }
        if showsFocus, sid == focusedID { return ThemeStore.shared.current.accentColor.opacity(0.55) }
        return .clear
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
            Text(focusedSession?.spec.label ?? String(localized: "终端"))
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
    @Environment(\.modelContext) private var modelContext

    @State private var searchModel = TerminalSearchModel()
    @State private var isSearchActive = false
    @State private var editingHost: Host?
    @State private var confirmingDelete = false

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

                disconnectCard
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: session.state)

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
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil, onConnect: { updated in
                // 用新配置重连:关掉失败的会话,重新解析 spec 开新会话(旧 spec 冻结了改动前的认证方式)
                sessionManager.closePane(session)
                let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? [updated]) + SSHConfigService.shared.mirrorHosts
                updated.lastConnectedAt = Date()
                _ = sessionManager.open(spec: HostSpec.resolve(updated, in: all))
            })
        }
        .confirmationDialog(
            "删除主机「\(session.spec.label)」?",
            isPresented: $confirmingDelete
        ) {
            Button("删除", role: .destructive) { deleteHost() }
            Button("取消", role: .cancel) { confirmingDelete = false }
        } message: {
            Text(deleteWarning)
        }
    }

    private var deleteWarning: String {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        if all.first(where: { $0.id == hostID })?.source == .sshConfig {
            return String(localized: "会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
        return String(localized: "Keychain 中保存的凭据会一并删除,此操作不可撤销。")
    }

    /// 删除主机并关闭该会话;config 镜像从 ~/.ssh/config 移除(自动备份)
    private func deleteHost() {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        if let host = all.first(where: { $0.id == hostID }) {
            if host.source == .sshConfig {
                SSHConfigService.shared.removeHostFromConfig(alias: host.label)
            } else {
                KeychainStore.deleteSecrets(for: host.id)
                modelContext.delete(host)
                // 显式保存,让侧栏 @Query 立即刷新
                try? modelContext.save()
            }
        }
        sessionManager.closePane(session)
    }

    /// 断线横幅的编辑入口:托管主机直接编辑;config 镜像优先复用已转换的托管主机,
    /// 否则给一份未入库的副本(保存时才入库,取消不留脏数据)
    private func editHost() {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        guard let host = all.first(where: { $0.id == hostID }) else { return }
        if host.source == .sshConfig {
            if let existing = all.first(where: {
                $0.source != .sshConfig
                    && $0.hostname == host.hostname
                    && $0.port == host.port
                    && $0.username == host.username
            }) {
                editingHost = existing
            } else {
                editingHost = Host(
                    label: host.label,
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    authMethod: host.authMethod,
                    privateKeyPath: host.privateKeyPath,
                    note: host.note
                )
            }
        } else {
            editingHost = host
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
        case .idle, .connected, .disconnected:
            EmptyView()
        }
    }

    /// 断线呈现:紧凑居中卡片(原生 alert 布局)—— 图标内联标题,文案左对齐,按钮右对齐
    @ViewBuilder
    private var disconnectCard: some View {
        if case .disconnected(let reason) = session.state {
            let accent: Color = reason == .userInitiated ? .secondary : .red
            let theme = ThemeStore.shared.current
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                    Text(session.spec.label)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                }
                Text("\(session.spec.username)@\(session.spec.hostname)")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason.message ?? String(localized: "连接已断开"))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if session.isAutoReconnectScheduled {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("自动重连中(第 \(session.reconnectAttempt) 次)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("停止") { session.cancelAutoReconnect() }
                            .controlSize(.small)
                        Spacer()
                    }
                }
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Text("删除")
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button {
                        editHost()
                    } label: {
                        Text("编辑主机")
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        session.connect()
                    } label: {
                        Text("立即重连")
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(18)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.elevatedBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
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
