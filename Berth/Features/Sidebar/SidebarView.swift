import AppKit
import SwiftData
import SwiftUI

/// 侧栏(双栏布局的左栏):搜索 + 一个平铺主机列表 + 底部密钥入口。
/// 按用户要求不做分组树:所有主机(托管 + ssh_config 镜像)一列到底,
/// 两行行样式 —— 标题 + user@host 副标题;config 镜像带文档角标。
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Host.sortOrder) private var storedHosts: [Host]
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @State private var spaceStore = SpaceStore.shared
    @AppStorage(SettingsKeys.demoMode) private var demoMode = false

    /// 托管主机(库)+ config 镜像(内存);演示模式下换内置示例(防录屏/截图泄漏)
    private var allHosts: [Host] {
        demoMode ? DemoMode.samples : storedHosts + SSHConfigService.shared.mirrorHosts
    }

    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true
    @State private var searchText = ""
    /// 主题配色面板(popover)
    @State private var isThemePanelPresented = false
    /// 底部「更多」弹窗(仪表盘/配色/设置)
    @State private var isMorePresented = false

    // 编辑/删除状态(删除只存快照,不持有模型 —— 模型可能被 config 同步等外部删除,悬空访问会崩溃)
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var hostPendingDeletion: PendingHost?
    @State private var configHostPendingDeletion: PendingHost?

    private struct PendingHost: Identifiable {
        let id: UUID
        let label: String
    }

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var visibleHosts: [Host] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allHosts }
        return allHosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    /// 工作空间生效条件:有空间、非演示模式(演示列表不分组,也不泄漏真实空间名)
    private var spacesActive: Bool { !demoMode && !groups.isEmpty }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedSpace: HostGroup? {
        groups.first { $0.id == spaceStore.selectedID } ?? groups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            configHintRow
            if allHosts.isEmpty {
                emptyState
            } else if isSearching || !spacesActive {
                // 搜索跨全部空间;没有空间时保持扁平列表(功能零打扰)
                hostListPage(hosts: visibleHosts, emptyText: String(localized: "没有匹配的主机"))
            } else {
                spacePager
            }
            // 底部工具行与右侧悬浮状态栏同一水平线,分隔线画上去反而突兀
            keysRow
        }
        // 触控板在侧边栏上横扫切换工作空间(Arc 手势)
        .background(SpaceSwipeCatcher())
        // 侧边栏空白处右键即可管理工作空间(主机行/小圆点各有更近的菜单,不冲突)
        .contextMenu {
            Button("新建工作空间…") { SpacePrompt.create(in: modelContext) }
            if spacesActive, let space = selectedSpace {
                Button("重命名「\(space.name)」…") { SpacePrompt.rename(space, in: modelContext) }
                Divider()
                Button("删除工作空间「\(space.name)」", role: .destructive) { deleteSpace(space) }
            }
        }
        .task(id: groups.map(\.id)) { spaceStore.syncSpaces(groups.map(\.id)) }
        // 透明 chrome:不刷不透明底,让 NavigationSplitView 原生的 behind-window
        // 侧栏毛玻璃透出桌面,只叠 45% 主题 tint 保住配色气质(压黑档留给不透明模式,
        // 叠在玻璃上会发死黑);不透明模式维持原来的 chrome 带色
        .background {
            if translucentChrome {
                Color(nsColor: theme.backgroundNSColor).opacity(0.45).ignoresSafeArea()
            } else {
                theme.sidebarBackground.ignoresSafeArea()
            }
        }
        .task(id: allHosts.count) { updateReachabilityTargets() }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil, defaultGroupID: spacesActive ? selectedSpace?.id : nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil)
        }
        .confirmationDialog(
            "删除主机「\(hostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                // 按 id 重新取,模型可能已被外部删除
                if let pending = hostPendingDeletion,
                   let host = allHosts.first(where: { $0.id == pending.id }) {
                    KeychainStore.deleteSecrets(for: host.id)
                    AIChatHistory.deleteAll(hostKey: host.id.uuidString)
                    modelContext.delete(host)
                }
                hostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { hostPendingDeletion = nil }
        } message: {
            Text("Keychain 中保存的凭据会一并删除,此操作不可撤销。")
        }
        .confirmationDialog(
            "从 ~/.ssh/config 删除「\(configHostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { configHostPendingDeletion != nil },
                set: { if !$0 { configHostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let pending = configHostPendingDeletion {
                    SSHConfigService.shared.removeHostFromConfig(alias: pending.label)
                }
                configHostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { configHostPendingDeletion = nil }
        } message: {
            Text("会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
    }

    /// 搜索框 + 新建主机
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索主机", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit { connectSelectionOrFirst() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
            )

            PanelIconButton(symbol: "plus", help: String(localized: "新建主机")) { isCreatingHost = true }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onChange(of: searchText) { _, _ in
            if let selected = sessionManager.selectedHostID,
               !visibleHosts.contains(where: { $0.id == selected }) {
                sessionManager.selectedHostID = visibleHosts.first?.id
            }
        }
    }

    // MARK: - 工作空间(Arc 式,自 Termite 移植)

    /// 当前实际展示的行(键盘上下/回车/删除的作用域):搜索时是全量结果,
    /// 否则是当前空间的主机
    private var displayedHosts: [Host] {
        if isSearching || !spacesActive { return visibleHosts }
        return hosts(inSpace: spaceStore.selectedID)
    }

    private func hosts(inSpace id: UUID?) -> [Host] {
        guard let id else { return allHosts }
        return allHosts.filter { spaceStore.effectiveSpaceID(of: $0) == id }
    }

    /// 空间切换的 shared-axis 转场:当前页与相邻页同位叠放,一起做
    /// 「小位移 + 交叉淡入」;相邻页常驻(透明度 0),手势途中不构建新页面
    @ViewBuilder private var spacePager: some View {
        if groups.count > 1 {
            let progress = spaceStore.dragProgress
            let index = spaceStore.selectedIndex
            ZStack {
                if index > 0 {
                    spacePage(at: index - 1).modifier(SharedAxisSlide(progress: progress - 1))
                }
                if index < groups.count - 1 {
                    spacePage(at: index + 1).modifier(SharedAxisSlide(progress: progress + 1))
                }
                spacePage(at: index).modifier(SharedAxisSlide(progress: progress))
            }
            .clipped()
        } else {
            spacePage(at: 0)
        }
    }

    private func spacePage(at index: Int) -> some View {
        let space = groups.indices.contains(index) ? groups[index] : nil
        return hostListPage(
            hosts: hosts(inSpace: space?.id),
            emptyText: String(localized: "此工作空间还没有主机\n右键主机「移到工作空间」")
        )
    }

    /// 左侧固定:当前空间名(双击改名,横扫时轻微跟随淡出)
    @ViewBuilder private var spaceNameLabel: some View {
        if let space = selectedSpace {
            Text(space.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.18), value: space.id)
                .opacity(1 - min(1, abs(spaceStore.dragProgress)) * 0.8)
                .offset(x: spaceStore.dragProgress * 8)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { SpacePrompt.rename(space, in: modelContext) }
                .help(String(localized: "双击重命名"))
        }
    }

    /// 中间固定:小圆点指示器(点击/横扫切换,右键管理)
    private var spaceDots: some View {
        HStack(spacing: 4) {
            ForEach(groups) { space in
                SpaceDot(
                    name: space.name,
                    isSelected: space.id == selectedSpace?.id,
                    hasLiveSession: spaceHasLiveSession(space),
                    select: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            spaceStore.select(space.id)
                        }
                    },
                    rename: { SpacePrompt.rename(space, in: modelContext) },
                    create: { SpacePrompt.create(in: modelContext) },
                    remove: { deleteSpace(space) }
                )
            }
        }
        .contentShape(Rectangle())
        .help(String(localized: "点击小圆点或触控板横扫切换工作空间"))
    }

    /// 空间聚合状态:组内任一主机有活跃连接,未选中的小圆点转绿
    private func spaceHasLiveSession(_ space: HostGroup) -> Bool {
        allHosts.contains { host in
            guard spaceStore.effectiveSpaceID(of: host) == space.id else { return false }
            if case .connected = sessionManager.liveState(for: host.id) { return true }
            return false
        }
    }

    /// 删除工作空间:主机按「归属无效 → 第一个空间」规则自动回流,不动任何连接
    private func deleteSpace(_ space: HostGroup) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            modelContext.delete(space)
            try? modelContext.save()
        }
    }

    private func hostListPage(hosts: [Host], emptyText: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if hosts.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(hosts) { host in
                        HostRow(
                            host: host,
                            isSelected: sessionManager.selectedHostID == host.id,
                            theme: theme
                        )
                        // 按下即选中(AppKit 层,无手势判定延迟);⌘ 点按再开一条同主机
                        // 连接;右键仍走 .contextMenu
                        .overlay {
                            PressMouseLayer(
                                onPress: { activate(host) },
                                onCommandPress: { connect(host) }
                            )
                        }
                        .contextMenu { hostMenu(host) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.return) { connectSelectionOrFirst(); return .handled }
        .onKeyPress(.deleteForward) { requestDeleteSelection(); return .handled }
        .onKeyPress(KeyEquivalent("\u{7F}")) { requestDeleteSelection(); return .handled }
    }

    @ViewBuilder
    private func hostMenu(_ host: Host) -> some View {
        // 单击是「切过去」,这里明确是「再开一条」——同一台主机可以开多个标签
        Button("新建连接(⌘ 点按)") { connect(host) }
        // issue #11:新建连接可选开在当前 pane 的分屏里,而不只有新标签
        if sessionManager.selected != nil {
            Button("在分屏中连接(左右)") { splitConnect(host, axis: .horizontal) }
            Button("在分屏中连接(上下)") { splitConnect(host, axis: .vertical) }
        }
        Button("复制 IP") { copyToPasteboard(host.hostname) }
        Button("复制用户名") { copyToPasteboard(host.username) }
        Button("复制 ssh 命令") { copyToPasteboard(sshCommand(for: host)) }
        if !host.macAddress.isEmpty {
            Button("网络唤醒(Wake-on-LAN)") { wake(host) }
        }
        if !groups.isEmpty, !demoMode {
            Divider()
            Menu("移到工作空间") {
                ForEach(groups) { space in
                    Button {
                        move(host, to: space)
                    } label: {
                        if spaceStore.effectiveSpaceID(of: host) == space.id {
                            Label(space.name, systemImage: "checkmark")
                        } else {
                            Text(space.name)
                        }
                    }
                }
            }
        }
        Divider()
        if host.source == .sshConfig {
            Button("转为托管主机…") { convertToManaged(host) }
            Button("从 config 删除…", role: .destructive) {
                configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        } else {
            Button("编辑…") { editingHost = host }
            Button("删除…", role: .destructive) {
                hostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        }
    }

    /// 底部工具行:左 仪表盘入口,右 主题配色 + 设置(应用级功能放左下角,macOS 惯例)。
    /// 底部一行:左 固定空间名 | 中 居中圆点指示器 | 右 固定「更多」按钮
    /// (弹窗收纳 仪表盘/配色/设置);隐私模式开着时保留常亮眼睛提示。
    /// 密钥管理/隐私模式开关在 ⌘P 命令面板(低频功能不占常驻图标)
    private var keysRow: some View {
        ZStack {
            // 中间:空间指示器绝对居中,不随两侧内容宽度漂移
            if spacesActive, !isSearching {
                spaceDots
            }
            HStack(spacing: 2) {
                if spacesActive, !isSearching {
                    spaceNameLabel
                }

                Spacer()

                if PrivacyMode.shared.isOn {
                    // 打码进行中给个常亮提示,点击恢复;平时不占位(开关在 ⌘P)
                    PanelIconButton(
                        symbol: "eye.slash.fill",
                        help: String(localized: "隐私模式已开启:主机地址已打码,点击恢复"),
                        tint: ThemeStore.shared.current.accentColor
                    ) {
                        PrivacyMode.shared.isOn.toggle()
                    }
                }
                PanelIconButton(
                    symbol: "ellipsis.circle",
                    help: String(localized: "更多:仪表盘 / 配色 / 设置")
                ) {
                    isMorePresented.toggle()
                }
                // 有新版本时在「更多」按钮上挂个小圆点提示
                .overlay(alignment: .topTrailing) {
                    if UpdateChecker.shared.available != nil {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
                .popover(isPresented: $isMorePresented, arrowEdge: .top) {
                    morePopover
                }
                .popover(isPresented: $isThemePanelPresented, arrowEdge: .top) {
                    ThemePanelView()
                }
            }
        }
        .padding(.horizontal, 8)
        // 与右侧终端底部的悬浮状态栏同高同底距,两边内容横向对齐成一条线
        .frame(height: 28)
        .padding(.bottom, 14)
    }

    /// 「更多」小弹窗:低频入口一处收纳,行样式与应用一致
    private var morePopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let update = UpdateChecker.shared.available {
                MorePopoverRow(
                    icon: "arrow.up.circle.fill",
                    title: String(localized: "新版本 \(update.version) 可用 —— 点击查看"),
                    tint: theme.accentColor
                ) {
                    isMorePresented = false
                    UpdateChecker.shared.openReleasePage(update)
                }
                Divider().padding(.vertical, 3)
            }
            MorePopoverRow(
                icon: "chart.bar.xaxis",
                title: String(localized: "仪表盘"),
                shortcut: "⌘0",
                tint: sessionManager.isDashboardVisible ? theme.accentColor : nil
            ) {
                isMorePresented = false
                withAnimation(.easeOut(duration: 0.18)) {
                    sessionManager.isDashboardVisible.toggle()
                }
            }
            MorePopoverRow(icon: "paintpalette", title: String(localized: "终端配色")) {
                isMorePresented = false
                // 弹窗收起后再开配色面板,两个 popover 不打架
                DispatchQueue.main.async { isThemePanelPresented = true }
            }
            SettingsLink {
                MorePopoverRowLabel(icon: "gearshape", title: String(localized: "设置"), shortcut: "⌘,")
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { isMorePresented = false })
        }
        .padding(6)
        .frame(width: 190)
    }

    /// config 里出现了没在导入面板见过的主机时,给一条可点的轻提示(而不是自己冒出来)
    @ViewBuilder
    private var configHintRow: some View {
        let pending = SSHConfigImportPolicy.shared
            .unseenAliases(among: SSHConfigService.shared.candidates.map(\.alias))
        if !pending.isEmpty {
            Button {
                OnboardingController.shared.presentImportPanel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("ssh_config 新增 \(pending.count) 个主机")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.accentSoft)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("还没有主机")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                isCreatingHost = true
            } label: {
                Label("新建主机", systemImage: "plus")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            if !SSHConfigService.shared.candidates.isEmpty {
                Button("从 ~/.ssh/config 导入…") {
                    OnboardingController.shared.presentImportPanel()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Text("也可 ⌘K 粘贴 ssh 命令直连")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    /// 单击行 = 切到这台主机:已经开着就切过去,没开才拨号。
    /// (否则单击连接会让在侧栏上下点几下就攒出一堆同主机标签)
    private func activate(_ host: Host) {
        sessionManager.selectedHostID = host.id
        if let existing = sessionManager.sessions.first(where: { $0.spec.hostID == host.id }) {
            sessionManager.focusPane(existing.id)
            return
        }
        connect(host)
    }

    /// 明确要「再开一个」:⌘ 点按、右键菜单、⌘K 等。总是新拨号,不借用旧连接 ——
    /// 旧会话的 spec 可能已过时(主机编辑后 hostID 不变),借用会静默连到老端点;
    /// 断网后的假活连接(state 还是 connected)借来也只会失败且不自动重连。
    /// 想复用连接开新 PTY 用 ⌘T(复制当前连接)。
    private func connect(_ host: Host) {
        sessionManager.selectedHostID = host.id
        host.lastConnectedAt = Date()
        sessionManager.open(spec: HostSpec.resolve(host, in: allHosts))
    }

    /// issue #11:在当前聚焦 pane 旁分屏连接该主机
    private func splitConnect(_ host: Host, axis: SplitAxis) {
        sessionManager.selectedHostID = host.id
        host.lastConnectedAt = Date()
        sessionManager.splitFocused(axis: axis, spec: HostSpec.resolve(host, in: allHosts))
    }

    /// 移到工作空间:托管主机写 group 关系(随 CloudKit 同步);
    /// ssh_config 镜像主机不入库,归属写本机映射
    private func move(_ host: Host, to space: HostGroup) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if host.source == .sshConfig {
                spaceStore.assignMirrorHost(host.id, to: space.id)
            } else {
                host.group = space
                try? modelContext.save()
            }
        }
    }

    /// 网络唤醒:向本机所在子网 + 全局广播发 magic packet
    private func wake(_ host: Host) {
        var broadcasts = ["255.255.255.255"]
        if let subnet = WakeOnLAN.subnetBroadcast(for: host.hostname) {
            broadcasts.insert(subnet, at: 0)
        }
        try? WakeOnLAN.wake(mac: host.macAddress, broadcasts: broadcasts)
    }

    /// 把直连主机(无跳板/无代理)喂给可达性探测
    private func updateReachabilityTargets() {
        let targets = allHosts.map { host in
            (id: host.id, host: host.hostname, port: host.port,
             direct: host.jumpHostID == nil && host.proxy.kind == .none)
        }
        HostReachability.shared.updateTargets(targets)
    }

    /// 回车:有选中连选中,否则连第一个可见结果(搜索场景)
    private func connectSelectionOrFirst() {
        let rows = displayedHosts
        if let selected = sessionManager.selectedHostID,
           let host = rows.first(where: { $0.id == selected }) {
            activate(host)
        } else if !searchText.isEmpty, let first = rows.first {
            activate(first)
        }
    }

    private func moveSelection(_ delta: Int) {
        let rows = displayedHosts
        guard !rows.isEmpty else { return }
        guard let current = sessionManager.selectedHostID,
              let index = rows.firstIndex(where: { $0.id == current }) else {
            sessionManager.selectedHostID = delta > 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = min(max(index + delta, 0), rows.count - 1)
        sessionManager.selectedHostID = rows[next].id
    }

    private func requestDeleteSelection() {
        guard let selected = sessionManager.selectedHostID,
              let host = displayedHosts.first(where: { $0.id == selected }) else { return }
        if host.source == .sshConfig {
            configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
        } else {
            hostPendingDeletion = PendingHost(id: host.id, label: host.label)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sshCommand(for host: Host) -> String {
        var command = "ssh \(host.username)@\(host.hostname)"
        if host.port != 22 { command += " -p \(host.port)" }
        if host.authMethod == .privateKeyFile, let keyPath = host.privateKeyPath, !keyPath.isEmpty {
            command += " -i \(keyPath)"
        }
        return command
    }

    /// ssh_config 镜像主机 → 可编辑的托管副本
    private func convertToManaged(_ host: Host) {
        // 已转换过 → 直接编辑现有托管主机,不再造副本
        if let existing = allHosts.first(where: {
            $0.source != .sshConfig
                && $0.hostname == host.hostname
                && $0.port == host.port
                && $0.username == host.username
        }) {
            editingHost = existing
            return
        }
        // 未入库的副本:保存时才入库,取消不留脏数据
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
}

/// 「更多」弹窗的一行:图标 + 标题 + 快捷键,悬停提亮
private struct MorePopoverRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MorePopoverRowLabel(icon: icon, title: title, shortcut: shortcut, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct MorePopoverRowLabel: View {
    let icon: String
    let title: String
    var shortcut: String?
    var tint: Color?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// 工作空间小圆点(Arc 底部指示器,自 Termite 移植):单色——选中=亮点并放大,
/// 未选中=暗点、悬停提亮;组内有活跃连接且未选中时转绿。右键新建与管理
private struct SpaceDot: View {
    let name: String
    let isSelected: Bool
    var hasLiveSession = false
    let select: () -> Void
    let rename: () -> Void
    let create: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isSelected { return Color.primary.opacity(0.5) }
        if hasLiveSession { return Color.green.opacity(0.55) }
        return Color.primary.opacity(hovering ? 0.32 : 0.15)
    }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
            .scaleEffect(hovering && !isSelected ? 1.25 : 1)
            // 点太小不好点:外扩一圈隐形命中区
            .frame(width: 16, height: 16)
            .contentShape(Circle())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { select() }
            .contextMenu {
                Button("重命名") { rename() }
                Button("新建工作空间…") { create() }
                Divider()
                Button("删除工作空间(主机归入第一个空间)", role: .destructive) { remove() }
            }
            .help(name)
    }
}

/// shared-axis 转场的单页姿态(自 Termite 移植)。progress 0 = 正位且不透明;
/// ±1 = 让到一侧并完全透明。位移只有 36pt——「轻盈」来自小位移 + 透明度交接
private struct SharedAxisSlide: ViewModifier {
    let progress: CGFloat

    private var clamped: CGFloat { max(-1, min(1, progress)) }

    func body(content: Content) -> some View {
        content
            .offset(x: clamped * 36)
            .opacity(Double(1 - abs(clamped)))
            // 让出去的一页同时收一点,避免纯平移的呆板
            .scaleEffect(1 - abs(clamped) * 0.02, anchor: .center)
            // 透明的页不该还能点
            .allowsHitTesting(abs(clamped) < 0.5)
    }
}

/// 主机行(Termite 同款设计语言):图标列 + 状态竖条 + 13pt 标题 + 10pt 等宽副标题
/// (竖条:连接态 > 可达性 > 标签色);选中 = 浮起材质,不用强调色水洗
private struct HostRow: View {
    let host: Host
    var isSelected = false
    let theme: TerminalTheme
    @Environment(SessionManager.self) private var sessionManager

    @State private var hovering = false
    @State private var reachability = HostReachability.shared

    var body: some View {
        HStack(spacing: 8) {
            // Finder 式图标列:固定宽度对齐成列
            OSBadge(osName: host.osName)
                .frame(width: 20)
            // 状态竖条:连接态 > 可达性 > 标签色,连接中带辉光
            RoundedRectangle(cornerRadius: 1.5)
                .fill(barColor)
                .frame(width: 3, height: 26)
                .shadow(
                    color: {
                        if case .connected = sessionManager.liveState(for: host.id) {
                            return Color.green.opacity(0.6)
                        }
                        return .clear
                    }(),
                    radius: 3
                )
            VStack(alignment: .leading, spacing: 1.5) {
                Text(PrivacyMode.shared.maskHost(in: host.label, hostname: host.hostname))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(PrivacyMode.shared.maskHost(in: host.address, hostname: host.hostname))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .help("来自 ~/.ssh/config(只读)")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        // 选中 = 浮起(与标题栏选中标签同一块材质);悬停只给 6% 底确认目标形状
        .background {
            if isSelected {
                RaisedCapsule()
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("\(PrivacyMode.shared.maskHost(in: host.address, hostname: host.hostname))\(host.lastConnectedAt.map { String(localized: " · 最近连接 ") + $0.formatted(.relative(presentation: .named)) } ?? "")")
    }

    /// 竖条颜色:连接态 > 可达性 > 标签色;全无信息时回落淡灰
    private var barColor: Color {
        switch sessionManager.liveState(for: host.id) {
        case .connected: return .green
        case .connecting: return .yellow
        case .none:
            switch reachability.statuses[host.id] {
            case .reachable: return Color.green.opacity(0.5)
            case .unreachable: return Color.red.opacity(0.4)
            case .unknown, nil:
                return host.tagColor == .none ? Color.gray.opacity(0.18) : host.tagColor.color.opacity(0.45)
            }
        }
    }
}


/// 设置入口:SettingsLink 套 PanelIconButton 同款外观(SettingsLink 不能换成普通 Button,
/// macOS 14+ 打开设置窗口只有这一个受支持入口)
private struct SettingsIconLink: View {
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("设置(⌘,)")
    }
}

/// 通用行悬停底色
private struct RowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Capsule()
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension TagColor {
    var color: Color {
        switch self {
        case .none: return .gray
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
