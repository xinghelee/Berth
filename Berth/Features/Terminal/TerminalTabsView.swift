import SwiftData
import SwiftUI

/// 右侧终端区:标签条 + 当前会话终端 + 断线横幅。
struct TerminalTabsView: View {
    /// 主窗口实测宽度:用于把标签区铺到右侧操作组前,不随侧栏显隐抖动。
    let windowWidth: CGFloat
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    /// chip 拖拽重排状态(AppKit 事件层驱动):dragOffset 是拖拽中 chip 的视觉位移,
    /// dragSwapShift 累计交换补偿 —— 交换后 chip 的基准位置移动了,要从鼠标 ΔX 里扣掉
    @State private var draggingChip: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragSwapShift: CGFloat = 0
    @State private var chipFrames: [UUID: CGRect] = [:]
    /// 「将当前目录存为本地 Shell 书签」的未入库草稿(编辑器保存时才插入)
    @State private var bookmarkDraft: Host?
    @AppStorage("inspectorRailWidth") private var railWidth: Double = InspectorRail.defaultWidth
    private static let chipSpacing: CGFloat = 2
    private static let chipTrackSpace = "chipTrack"
    /// 调试开关:在 macOS 26+ 上强制走 15 的工具条路径,方便本机复现/验收 issue #14
    private static let forcesLegacyChrome =
        ProcessInfo.processInfo.environment["BERTH_LEGACY_CHROME"] == "1"
    /// 26+ 现代工具条(Liquid Glass):标签轨道等视觉只在这条路径生效
    static let modernChrome: Bool = {
        if #available(macOS 26.0, *) { return !forcesLegacyChrome }
        return false
    }()

    /// 检查器栏宽度上限随窗口走:至少给终端留一半多,窗口缩小后已存的宽度也按此夹取
    private func clampedRailWidth(_ width: CGFloat) -> CGFloat {
        let upper = max(InspectorRail.minWidth, min(InspectorRail.maxWidth, windowWidth * 0.45))
        return min(max(width, InspectorRail.minWidth), upper)
    }

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            if sessionManager.isDashboardVisible {
                // ⌘0:终端区整体让给仪表盘。标签条还在标题栏上,点任一 chip 即切回终端;
                // 会话本身完全不受影响(与切标签同一条路径,scrollback 由会话持有)
                DashboardView(isEmbedded: true)
                    .transition(.opacity)
            } else if sessionManager.tabs.isEmpty {
                emptyState
            } else if let tab = sessionManager.selectedTab {
                if tab.isBroadcasting {
                    broadcastBanner
                }
                HStack(spacing: 0) {
                    // 单 pane 不显示焦点边框(只有分屏时才需要区分)
                    PaneTreeView(
                        node: tab.root,
                        tab: tab,
                        focusedID: tab.focusedID,
                        showsFocus: tab.root.leafIDs().count > 1,
                        broadcasting: tab.isBroadcasting
                    ) { id in
                        sessionManager.focusPane(id)
                    }
                    if let session = sessionManager.selected, sessionManager.activeSidePanel != nil {
                        // 检查器栏(Xcode inspector 式):顶部图标条选面板,整条随开关进出;
                        // 左缘可拖拽调宽(issue #37),双击复位
                        PaneDivider(
                            axis: .horizontal,
                            thickness: 6,
                            step: 1,
                            onDrag: { delta in railWidth = clampedRailWidth(railWidth - delta) },
                            onReset: { railWidth = InspectorRail.defaultWidth }
                        )
                        InspectorRail(session: session, width: clampedRailWidth(railWidth))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if let session = sessionManager.selected {
                    StatusBarView(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
        // automatic 不会像 navigation placement 那样随侧栏一起消失。
        .toolbar {
            if #available(macOS 26.0, *) {
                if Self.forcesLegacyChrome { legacyToolbarContent } else { modernToolbarContent }
            } else {
                legacyToolbarContent
            }
        }
        .sheet(item: $bookmarkDraft) { draft in
            HostEditorView(host: draft, defaultGroupID: nil)
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
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { manager.pendingCloseSession = nil }
        } message: {
            Text(sessionManager.pendingCloseSession?.spec.isLocal == true
                ? String(localized: "该分屏有正在运行的本地 Shell。")
                : String(localized: "该分屏有活跃的 SSH 连接。"))
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
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { manager.pendingCloseTab = nil }
        } message: {
            Text({
                let firstLeaf = sessionManager.pendingCloseTab?.root.firstLeaf
                let isLocal = firstLeaf.flatMap { sessionManager.session($0) }?.spec.isLocal == true
                return isLocal
                    ? String(localized: "该标签页含正在运行的本地 Shell(可能有多个分屏)。")
                    : String(localized: "该标签页含活跃的 SSH 连接(可能有多个分屏)。")
            }())
        }
    }

    /// macOS 26:原生 ToolbarSpacer 把操作组真正锚到右边缘。
    @available(macOS 26.0, *)
    @ToolbarContentBuilder
    private var modernToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if !sessionManager.tabs.isEmpty { toolbarTabs }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // 藏系统玻璃底(它是椭圆),按钮自绘正圆
        ToolbarItem(placement: .automatic) {
            if !sessionManager.tabs.isEmpty { panelButtons }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// macOS 15:没有 ToolbarSpacer,合成单个 item 走 Xcode 式「可伸缩中区」——
    /// item 被 ToolbarStretchPin 钉成 stretchable,NSToolbar 把剩余宽度全分给它,
    /// 内部 Spacer 把按钮组推到右缘。宽度零测量,侧栏收放/窗口缩放由 AppKit 收敛。
    @ToolbarContentBuilder
    private var legacyToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if !sessionManager.tabs.isEmpty {
                HStack(spacing: 8) {
                    tabChips
                    Spacer(minLength: 8)
                    panelButtons
                }
                .frame(maxWidth: .infinity)
                .background(ToolbarStretchPin(
                    overflowTabs: {
                        sessionManager.tabs.map { tab in
                            ToolbarStretchPin.OverflowTab(
                                id: tab.id,
                                title: overflowTabTitle(tab),
                                isSelected: tab.id == sessionManager.selectedTabID
                            )
                        }
                    },
                    onSelectTab: { sessionManager.selectTab($0) }
                ).frame(width: 1, height: 1))
            }
        }
    }

    /// » 溢出菜单里的标签名:与 chip 显示规则一致(自定义名 > 聚焦会话打码 label)
    private func overflowTabTitle(_ tab: PaneTab) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        return sessionManager.session(tab.focusedID)?.tabTitle ?? String(localized: "终端")
    }

    /// 从系统侧栏按钮之后使用可用空间,多标签在其中横向滚动。
    private var toolbarTabs: some View {
        tabChips
            // 为远程会话完整的 6 个操作按钮预留容量;剩余空间由 ToolbarSpacer
            // 吸收,所以本地 Shell 的较短按钮组仍会贴紧窗口右端。
            .frame(width: max(windowWidth - 500, 220), alignment: .leading)
    }

    /// 标签 chips(标题栏左侧):每个标签一枚 chip(含嵌套分屏);两端渐隐,选中自动滚入;
    /// 「+」新建菜单跟在最后一个 chip 后(Chrome 式),随标签一起滚动
    private var tabChips: some View {
        ScrollViewReader { proxy in
            // 注意不能用 GlassEffectContainer 包 chips:容器会把玻璃合并抬到
            // 独立层、压在文字上方,标签文字被折射得看不清(26.0 实测)
            ScrollView(.horizontal, showsIndicators: false) { chipTrack }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 临时本地 Shell 标签的右键「存为书签」:草稿预填当前目录,名字取目录名
    private func saveAsBookmarkAction(for tab: PaneTab) -> (() -> Void)? {
        guard let session = sessionManager.session(tab.focusedID),
              session.spec.isLocal, session.spec.hostID == HostSpec.localShellHostID else { return nil }
        return {
            let dir = session.currentRemoteDirectory ?? ""
            let draft = Host(label: "", hostname: "localhost", port: 0, username: NSUserName())
            draft.isLocalShell = true
            draft.localDirectory = dir.isEmpty ? "" : LocalPath.abbreviate(dir)
            draft.label = tab.customTitle ?? LocalPath.shortName(dir.isEmpty ? "~" : dir)
            bookmarkDraft = draft
        }
    }

    /// chips 轨道
    private var chipTrack: some View {
        HStack(spacing: Self.chipSpacing) {
            ForEach(sessionManager.tabs) { tab in
                TerminalTabChip(
                    tab: tab,
                    focusedSession: sessionManager.session(tab.focusedID),
                    paneCount: tab.root.leafIDs().count,
                    isSelected: tab.id == sessionManager.selectedTabID,
                    select: { sessionManager.selectTab(tab.id) },
                    close: { sessionManager.requestCloseTab(tab) },
                    onSaveAsBookmark: saveAsBookmarkAction(for: tab),
                    onDragChanged: { chipDragChanged(tab, deltaX: $0) },
                    onDragEnded: { chipDragEnded(tab) }
                )
                .offset(x: draggingChip == tab.id ? dragOffset : 0)
                .zIndex(draggingChip == tab.id ? 1 : 0)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.chipTrackSpace))
                } action: { chipFrames[tab.id] = $0 }
                .id(tab.id)
            }
            newTabMenu
        }
        // 轨道垫到 36pt(chip 25pt + 上下 5.5)对齐系统工具栏控件高度——
        // 右侧玻璃按钮簇实测 36pt,矮一截会显得两头不齐(仅 26+;15 无轨道不加高)
        .padding(.horizontal, 4)
        .padding(.vertical, Self.modernChrome ? 5.5 : 2)
        // 标签条整体一条浅色轨道底(分段控件式),选中玻璃浮在轨道上;
        // 15 的 chips 各自带描边,不再叠轨道
        .background {
            if Self.modernChrome {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        // 拖拽中交换即时生效(跟手),松手后的归位走 spring
        .animation(
            draggingChip == nil ? .spring(response: 0.25, dampingFraction: 0.9) : nil,
            value: sessionManager.tabs.map(\.id)
        )
        // 选中态迁移带轻动画(浮起材质淡入淡出;终端内容不参与)
        .animation(.easeInOut(duration: 0.22), value: sessionManager.selectedTabID)
        .coordinateSpace(name: Self.chipTrackSpace)
        .padding(.horizontal, 10)
    }

    // MARK: - chip 拖拽重排(AppKit 事件层驱动,新老系统一致)

    private func chipDragChanged(_ tab: PaneTab, deltaX: CGFloat) {
        if draggingChip != tab.id {
            draggingChip = tab.id
            dragSwapShift = 0
        }
        dragOffset = deltaX - dragSwapShift
        swapIfCrossedNeighbor(tab)
    }

    /// 拖拽中 chip 的视觉中线越过邻居中线 → 数组交换 + 位移补偿(基准位置变了)
    private func swapIfCrossedNeighbor(_ tab: PaneTab) {
        guard let frame = chipFrames[tab.id],
              let index = sessionManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let currentMidX = frame.midX + dragOffset
        if dragOffset > 0, index + 1 < sessionManager.tabs.count {
            let neighbor = sessionManager.tabs[index + 1]
            if let neighborFrame = chipFrames[neighbor.id], currentMidX > neighborFrame.midX {
                sessionManager.moveTab(tab.id, to: index + 1)
                let shift = neighborFrame.width + Self.chipSpacing
                dragSwapShift += shift
                dragOffset -= shift
            }
        } else if dragOffset < 0, index - 1 >= 0 {
            let neighbor = sessionManager.tabs[index - 1]
            if let neighborFrame = chipFrames[neighbor.id], currentMidX < neighborFrame.midX {
                sessionManager.moveTab(tab.id, to: index - 1)
                let shift = neighborFrame.width + Self.chipSpacing
                dragSwapShift -= shift
                dragOffset += shift
            }
        }
    }

    private func chipDragEnded(_ tab: PaneTab) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { dragOffset = 0 }
        // 归位动画期间保持 zIndex/offset 归属,结束再释放拖拽态
        let settled = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if draggingChip == settled { draggingChip = nil }
        }
    }

    /// 「+」新建菜单:本地 Shell / 复制当前连接 / 快速连接
    private var newTabMenu: some View {
        Menu {
            Button {
                _ = sessionManager.open(spec: .localShell())
            } label: {
                Label(String(localized: "新建本地 Shell"), systemImage: "terminal")
            }
            Button {
                sessionManager.duplicateCurrent()
            } label: {
                Label(String(localized: "复制当前连接为新标签"), systemImage: "plus.square.on.square")
            }
            .disabled(sessionManager.selected == nil)
            Button {
                QuickConnectController.shared.toggle()
            } label: {
                Label(String(localized: "快速连接…"), systemImage: "bolt.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建标签页(本地 Shell / 快速连接)")
    }

    /// 检查器栏开关(Xcode 式,标题栏右侧):单个按钮整体展开/收起,
    /// 具体面板在栏内顶部的图标条上选(⌘⇧A/⌘⇧F/⌘I/⌘⇧S 仍直达对应面板)。
    /// 外观对齐左侧系统侧栏按钮:同尺寸圆形液态玻璃底 + 主色大图标
    /// (系统给单按钮的玻璃底是椭圆,已在 toolbar item 上藏掉,这里自绘正圆)
    private var panelButtons: some View {
        InspectorToggleButton {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                sessionManager.toggleInspectorRail()
            }
        }
    }

    private struct InspectorToggleButton: View {
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    // 水平镜像:面板线条移到右侧,对应右侧检查器
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: 34, height: 34)
                    .background {
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect(.regular, in: .circle)
                        } else {
                            Circle()
                                .fill(ThemeStore.shared.current.elevatedBackground)
                                .overlay(Circle().stroke(ThemeStore.shared.current.borderColor, lineWidth: 1))
                        }
                    }
                    .overlay {
                        if hovering {
                            Circle().fill(Color.primary.opacity(0.06))
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(PressableIconStyle())
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .help(String(localized: "检查器栏:AI / SFTP / 信息 / Docker / 片段"))
        }
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
            Text("点击左侧主机开始连接")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    QuickConnectController.shared.toggle()
                } label: {
                    Label(String(localized: "快速连接"), systemImage: "bolt.fill")
                }
                Button {
                    _ = sessionManager.open(spec: .localShell())
                } label: {
                    Label(String(localized: "本地 Shell"), systemImage: "terminal")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 6)
            Text(verbatim: "⌘K · ⇧⌘T")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 分屏树递归视图:叶子=一个终端 pane(可点按聚焦、聚焦有强调边框),分支=按方向二分。
/// 分支按 tab 上记录的比例分配,分割线可拖(双击复位对半)。
private struct PaneTreeView: View {
    let node: PaneNode
    let tab: PaneTab
    let focusedID: UUID
    var showsFocus: Bool = true
    var broadcasting: Bool = false
    let onFocus: (UUID) -> Void
    @Environment(SessionManager.self) private var sessionManager

    /// 分割线占位厚度:可见线只有 1pt,但抓取带必须自己占住布局 ——
    /// 靠 overlay 往两侧溢出是抓不着的,那片区域压在终端 NSView 上,
    /// AppKit 命中测试会把鼠标事件判给终端
    private static let dividerThickness: CGFloat = 6
    /// 每侧至少留这么多点,拖到头也不会把 pane 压没
    private static let minPaneLength: CGFloat = 120

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
        case .branch(let branchID, let axis, let first, let second):
            GeometryReader { proxy in
                let total = axis == .horizontal ? proxy.size.width : proxy.size.height
                let available = max(total - Self.dividerThickness, 1)
                // 布局时也按最小 pane 尺寸夹取:拖拽路径的下限只约束当时的窗口宽度,
                // 大窗口拖到 0.94 再缩小窗口,原比例会把另一侧压成几十点的废纸条
                let raw = (available * tab.ratio(of: branchID)).rounded()
                let firstLength = available > Self.minPaneLength * 2
                    ? min(max(raw, Self.minPaneLength), available - Self.minPaneLength)
                    : raw
                let layout = axis == .horizontal
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    subtree(first)
                        .frame(
                            width: axis == .horizontal ? firstLength : nil,
                            height: axis == .vertical ? firstLength : nil
                        )
                    PaneDivider(
                        axis: axis,
                        thickness: Self.dividerThickness,
                        // 按字符格步进:格内的位移不改变终端行列数,却会让 SwiftTerm
                        // 每帧重排一次(带滚动回卷的重排很贵),拖起来就是一顿一顿的
                        step: cellStep(axis: axis, of: first),
                        onDrag: { delta in
                            let target = (firstLength + delta) / available
                            let floor = min(Self.minPaneLength / available, 0.5)
                            tab.setRatio(min(max(target, floor), 1 - floor), for: branchID)
                        },
                        onReset: { tab.resetRatio(for: branchID) }
                    )
                    subtree(second)
                }
            }
        }
    }

    /// 该侧终端一个字符格的大小(拖拽步进用);取不到就给个保守值
    private func cellStep(axis: SplitAxis, of node: PaneNode) -> CGFloat {
        guard let view = sessionManager.session(node.firstLeaf)?.terminalView else { return 8 }
        let terminal = view.getTerminal()
        if axis == .horizontal {
            return max(view.frame.width / CGFloat(max(terminal.cols, 1)), 4)
        }
        return max(view.frame.height / CGFloat(max(terminal.rows, 1)), 8)
    }

    private func subtree(_ child: PaneNode) -> some View {
        PaneTreeView(
            node: child, tab: tab, focusedID: focusedID,
            showsFocus: showsFocus, broadcasting: broadcasting, onFocus: onFocus
        )
    }

    private func borderColor(_ sid: UUID) -> Color {
        // 广播时所有 pane 橙色边框;否则仅聚焦 pane 强调色边框
        if broadcasting { return .orange.opacity(0.7) }
        if showsFocus, sid == focusedID { return ThemeStore.shared.current.accentColor.opacity(0.55) }
        return .clear
    }
}

/// 可拖拽的分割线:整条抓取带自己占位(见 dividerThickness),中间画 1pt 可见线;
/// 悬停变调整光标,双击复位对半。
/// delta 用增量(每帧的位移差)而不是 DragGesture 的累计 translation ——
/// 比例改了之后 firstLength 也跟着变,再用累计值算会自乘一遍,拖起来直接飞出去。
private struct PaneDivider: View {
    let axis: SplitAxis
    let thickness: CGFloat
    let step: CGFloat
    let onDrag: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var lastTranslation: CGFloat = 0
    /// 攒够一格才提交,不足一格的位移留到下一帧
    @State private var pending: CGFloat = 0
    @State private var isHovering = false
    /// 拖拽进行中:步进式移动会让光标短暂滑出抓取带,悬停态在拖拽期间要保持住,
    /// 否则强调色和光标形状一路闪
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isHovering || isDragging
                ? ThemeStore.shared.current.accentColor.opacity(0.55)
                : ThemeStore.shared.current.borderColor)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .frame(width: axis == .horizontal ? thickness : nil,
                   height: axis == .vertical ? thickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                guard !isDragging else { return }
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // 必须用 .global 量位移:默认 .local 以分割线自身为参照,而分割线
                // 拖着拖着自己就挪了 —— 参照系一移,translation 往回缩,增量算出
                // 反向位移,布局在两个位置间来回打摆(拖拽时一片框跳动)。
                // minimumDistance 4:双击时 1-2pt 的手抖会被 1pt 阈值当成微拖拽,
                // 吞掉双击复位(macOS 自己的拖拽判定阈值也是 ~4pt)
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        let current = axis == .horizontal ? value.translation.width : value.translation.height
                        pending += current - lastTranslation
                        lastTranslation = current
                        let whole = (pending / step).rounded(.towardZero)
                        guard whole != 0 else { return }
                        onDrag(whole * step)
                        pending -= whole * step
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslation = 0
                        pending = 0
                        if !isHovering { NSCursor.arrow.set() }
                    }
            )
            .onTapGesture(count: 2) { onReset() }
            // 不挂 .help:悬停气泡会在正要拖的时候弹出来挡住分割线
    }
}

private struct TerminalTabChip: View {
    let tab: PaneTab
    let focusedSession: TerminalSession?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    var onSaveAsBookmark: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var isHovering = false
    /// 双击/右键重命名:行内 TextField 编辑,回车/失焦提交,Esc 取消
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @AppStorage(SettingsKeys.tabFontSize) private var tabFontSize: Double = 12

    /// 自定义名优先;否则跟随聚焦会话(主机打码规则不变)
    private var displayTitle: String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        return focusedSession?.tabTitle ?? String(localized: "终端")
    }

    /// 本地会话悬停显示完整当前目录(标题只放最后一级)
    private var hoverHelp: String {
        guard let session = focusedSession, session.spec.isLocal,
              let dir = session.currentRemoteDirectory else { return "" }
        return LocalPath.abbreviate(dir)
    }

    private var scale: CGFloat { tabFontSize / 12 }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6 * scale, height: 6 * scale)
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: tabFontSize))
                    .frame(width: max(64 * scale, CGFloat(renameDraft.count) * 7 * scale + 14))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand {
                        isRenaming = false
                        focusedSession?.focusTerminal()
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, isRenaming { commitRename() }
                    }
            } else {
                Text(displayTitle)
                    .font(.system(size: tabFontSize))
                    .lineLimit(1)
            }
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.system(size: 9 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("\(paneCount) 个分屏")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8 * scale, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 0.7 : 0)
        }
        .padding(.horizontal, 11 * scale)
        .padding(.vertical, 5 * min(scale, 1.2))
        // 选中 = 浮起材质(与侧栏选中行同一块料,26+ 即 Liquid Glass),不用强调色水洗。
        // macOS 26+ 未选中不再描边(Safari 26 式安静标签),悬停给淡玻璃;
        // macOS 15 保留 1pt 发丝描边(拖拽重排的把手感)
        .background {
            if isSelected {
                RaisedCapsule()
            } else if isHovering {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: .capsule)
                } else {
                    Capsule().fill(Color.primary.opacity(0.05))
                }
            }
        }
        .overlay {
            if !isSelected, #unavailable(macOS 26.0) {
                Capsule().strokeBorder(ThemeStore.shared.current.borderColor, lineWidth: 1)
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        // 事件层用真 NSView:标题栏里 SwiftUI 手势抢不过窗口拖拽(macOS 15),
        // 且双 tap 组合会给单击加判定延迟。重命名时撤掉,让 TextField 接点击;
        // 尾部让出 × 按钮的响应区
        .overlay {
            if !isRenaming {
                PressMouseLayer(
                    onPress: select,
                    onDoubleClick: startRename,
                    onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded
                )
                .padding(.trailing, (isHovering || isSelected) ? 26 * scale : 0)
            }
        }
        .onHover { isHovering = $0 }
        .help(hoverHelp)
        .contextMenu {
            Button(String(localized: "重命名标签")) { startRename() }
            if tab.customTitle != nil {
                Button(String(localized: "恢复默认名称")) { tab.customTitle = nil }
            }
            if let onSaveAsBookmark {
                Button(String(localized: "将当前目录存为侧栏书签…"), action: onSaveAsBookmark)
            }
            Divider()
            Button(String(localized: "关闭标签页"), role: .destructive, action: close)
        }
    }

    private func startRename() {
        renameDraft = tab.customTitle ?? displayTitle
        isRenaming = true
        // TextField 要等下一个 runloop 挂上视图层级,focus 才生效
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        isRenaming = false
        focusedSession?.focusTerminal()
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
    @State private var dropModel = TerminalDropUploadModel()
    @State private var isDropTargeted = false
    @State private var editingHost: Host?
    @State private var confirmingDelete = false
    /// 最近一次断线原因;非 nil 即挂着断线卡片。连上才清空,重连失败只换文案不重挂
    @State private var lastDisconnect: TerminalSession.DisconnectReason?
    /// 最近一次尝试结束的时间 —— 重连失败时错误文案一字不变,没有它用户看不出点动过
    @State private var lastAttemptAt: Date?
    /// 保证转圈至少可见一会儿:EHOSTUNREACH 是瞬时失败,不兜底的话按钮闪都不闪
    @State private var isRetryingVisibly = false

    private var isConnecting: Bool {
        if case .connecting = session.state { return true }
        return false
    }

    private var showsRetrySpinner: Bool { isConnecting || isRetryingVisibly }

    private func retry() {
        isRetryingVisibly = true
        session.connect()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            isRetryingVisibly = false // 还没连完的话由 isConnecting 接着转
        }
    }

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
                    // 只在卡片进出时动;重连失败不该重放一遍入场动画
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: lastDisconnect == nil)

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

            TerminalDropOverlay(model: dropModel)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                // 分流:本地 Shell 按 Terminal.app 惯例把路径写进命令行;SSH 会话走 SFTP 上传
                if session.spec.isLocal {
                    return insertDroppedPaths(providers)
                }
                return dropModel.handleDrop(providers, session: session)
            }
            .onChange(of: isDropTargeted) { _, targeted in
                guard !session.spec.isLocal else { return }
                targeted ? dropModel.dragEntered(session: session) : dropModel.dragExited()
            }
        }
        .sheet(item: $dropModel.pendingBatch) { batch in
            DropDestinationSheet(batch: batch, model: dropModel, session: session)
        }
        .confirmationDialog(
            "远端已有同名文件",
            isPresented: Binding(
                get: { dropModel.pendingOverwrite != nil },
                set: { if !$0 { dropModel.pendingOverwrite = nil } }
            ),
            presenting: dropModel.pendingOverwrite
        ) { pending in
            Button("覆盖", role: .destructive) {
                dropModel.resolveOverwrite(pending, overwrite: true, session: session)
            }
            Button("跳过同名文件") {
                dropModel.resolveOverwrite(pending, overwrite: false, session: session)
            }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text("目标目录 \(pending.directory) 已存在:\(pending.conflicts.joined(separator: "、"))")
        }
        .task {
            // 启动恢复出来的标签是 idle 的(见 restoreSessions),切到哪个才连哪个
            if case .idle = session.state { session.connect() }
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .disconnected(let reason):
                lastDisconnect = reason
                lastAttemptAt = Date()
            case .connected:
                lastDisconnect = nil
                lastAttemptAt = nil
            case .connecting, .idle: break // 重连中:卡片留着,按钮转圈
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
        // 注意不能挂 onDismiss 兜底取消:它在收起动画后才触发,多轮质询(密码→MFA 码)
        // 时下一轮的 prompt/continuation 已就位,迟到的 onDismiss 会把第二轮误取消。
        // 取消只走 sheet 内按钮;会话断开时由 teardown 统一收掉挂起的质询。
        .sheet(item: $session.keyboardInteractivePrompt) { prompt in
            KeyboardInteractivePromptSheet(prompt: prompt, session: session)
        }
        .sheet(item: $editingHost) { host in
            // issue #11:从失败卡片进的编辑,「保存」也应立即生效 —— 否则卡片带着改动前的
            // 旧 spec 继续杵着,看起来像什么都没发生。保存/保存并连接统一走重开
            HostEditorView(
                host: host,
                defaultGroupID: nil,
                onConnect: { reopenWithUpdatedHost($0) },
                onSave: { reopenWithUpdatedHost($0) }
            )
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

    /// 本地 Shell 的拖拽:把文件路径(转义后)写进命令行,多个文件按拖入顺序空格分隔
    private func insertDroppedPaths(_ providers: [NSItemProvider]) -> Bool {
        let items = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !items.isEmpty else { return false }
        Task { @MainActor in
            var paths: [String] = []
            for provider in items {
                let url: URL? = await withCheckedContinuation { cont in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        cont.resume(returning: url)
                    }
                }
                if let url { paths.append(url.path) }
            }
            guard !paths.isEmpty else { return }
            session.sendText(paths.map(BerthTerminalView.shellEscaped).joined(separator: " ") + " ")
        }
        return true
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
                AIChatHistory.deleteAll(hostKey: host.id.uuidString)
                modelContext.delete(host)
                // 显式保存,让侧栏 @Query 立即刷新
                try? modelContext.save()
            }
        }
        sessionManager.closePane(session)
    }

    /// 用新配置重连:关掉失败的会话,重新解析 spec 开新会话(旧 spec 冻结了改动前的认证方式)
    private func reopenWithUpdatedHost(_ updated: Host) {
        sessionManager.closePane(session)
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? [updated]) + SSHConfigService.shared.mirrorHosts
        updated.lastConnectedAt = Date()
        _ = sessionManager.open(spec: HostSpec.resolve(updated, in: all))
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

    /// 断线呈现:紧凑居中卡片(原生 alert 布局)—— 图标内联标题,文案左对齐,按钮右对齐。
    /// 挂载条件是 `lastDisconnect` 而不是当前 state:重连期间卡片留在原地换成进度条,
    /// 否则一失败就是「卡片滑走 → 再从上面滑回来」,点几次重连眼睛要花。
    @ViewBuilder
    private var disconnectCard: some View {
        if let reason = lastDisconnect {
            let accent: Color = reason == .userInitiated ? .secondary : .red
            let theme = ThemeStore.shared.current
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                    Text(PrivacyMode.shared.maskHost(in: session.spec.label, hostname: session.spec.hostname))
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                    // issue #11:失败卡片要能立即关掉 —— 关闭该会话 pane,不必先重连成功
                    Button {
                        sessionManager.closePane(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭会话")
                }
                Text(session.spec.isLocal
                    ? LocalShell.resolvedShellPath()
                    : "\(session.spec.username)@\(PrivacyMode.shared.mask(session.spec.hostname))")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 重连期间不换文案:进度只体现在按钮上,卡片高度纹丝不动。
                // 换成进度行会让按钮整排上跳再弹回,点几次就是一片残影
                Text(reason.message ?? String(localized: "连接已断开"))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lastAttemptAt {
                    Text("最近尝试 \(lastAttemptAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
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
                    // 本地 Shell 没有主机记录,删除/编辑不适用
                    if !session.spec.isLocal {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Text("删除")
                                .font(.system(size: 13.5))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(showsRetrySpinner)
                        Button {
                            editHost()
                        } label: {
                            Text("编辑主机")
                                .font(.system(size: 13.5))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(showsRetrySpinner)
                    }
                    Button(action: retry) {
                        // 转圈期间按钮本身不置灰 —— 置灰的 ProgressView 看着像卡死。
                        // 靠 allowsHitTesting 挡住重复点击
                        ZStack {
                            Text("立即重连")
                                .opacity(showsRetrySpinner ? 0 : 1)
                            if showsRetrySpinner {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .font(.system(size: 13.5))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .allowsHitTesting(!showsRetrySpinner)
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
