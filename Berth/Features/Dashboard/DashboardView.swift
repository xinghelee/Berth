import AppKit
import SwiftData
import SwiftUI

/// 仪表盘排序方式
enum DashboardSort: String, CaseIterable, Identifiable {
    case name, status, cpu, memory, disk
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return String(localized: "名称")
        case .status: return String(localized: "状态")
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "内存")
        case .disk: return String(localized: "磁盘")
        }
    }
}

/// 仪表盘:所有主机的资源状态一屏看完。
///
/// 两种呈现共用这一个视图与同一个采集引擎:
///   - 内嵌(⌘0):主窗口终端区整体切过来,「看一眼 → 点进去连」不用切窗口;
///   - 独立窗口:想扔到第二块屏常驻的人,从工具条「在新窗口打开」撕出去。
/// 采集只在仪表盘可见时进行 —— 都关掉就断开监控连接,不在后台偷偷连服务器。
struct DashboardView: View {
    /// true = 嵌在主窗口终端区里(多一个「返回终端」与「在新窗口打开」)
    var isEmbedded = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Host.sortOrder) private var storedHosts: [Host]
    @AppStorage(SettingsKeys.demoMode) private var demoMode = false
    @AppStorage(SettingsKeys.dashboardInterval) private var interval = 5.0
    @AppStorage(SettingsKeys.dashboardSort) private var sortRaw = DashboardSort.name.rawValue
    @AppStorage(SettingsKeys.dashboardCardScale) private var cardScale = 1.0

    @State private var monitor = ServerMonitor.shared
    @State private var theme = ThemeStore.shared
    @State private var searchText = ""

    private var sort: DashboardSort { DashboardSort(rawValue: sortRaw) ?? .name }
    /// 用户偏好只允许预设档位;旧版或手改 defaults 的异常值也不能把布局撑坏。
    private var effectiveCardScale: CGFloat {
        switch cardScale {
        case 1.25, 1.5: return cardScale
        default: return 1
        }
    }

    /// 托管主机 + ssh_config 镜像;演示模式换内置示例(与侧栏同源)
    private var allHosts: [Host] {
        // 本地 Shell 书签没有服务器可采集
        demoMode ? DemoMode.samples : storedHosts.filter { !$0.isLocalShell } + SSHConfigService.shared.mirrorHosts
    }

    private var visibleStates: [ServerMonitor.HostState] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let states = monitor.order.compactMap { monitor.states[$0] }.filter { state in
            query.isEmpty
                || state.label.localizedCaseInsensitiveContains(query)
                || state.address.localizedCaseInsensitiveContains(query)
        }
        return states.sorted(by: Self.comparator(sort))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.current.borderColor)
            if monitor.order.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(theme.current.sidebarBackground.ignoresSafeArea())
        .tint(theme.current.accentColor)
        .task {
            monitor.setTargets(allHosts)
            monitor.start()
        }
        // 主机增删/改名后同步采集目标(SwiftData 变更会重算 allHosts)
        .onChange(of: allHosts.map(\.id)) { _, _ in monitor.setTargets(allHosts) }
        // 改间隔立刻生效,而不是等当前这一轮 sleep 结束(从 1 分钟改到 2 秒要等一分钟太蠢)
        .onChange(of: interval) { _, _ in monitor.refreshAll() }
        .onDisappear { monitor.stop() }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            if isEmbedded {
                PanelIconButton(symbol: "chevron.left", help: String(localized: "返回终端(⌘0)")) {
                    SessionManager.shared.isDashboardVisible = false
                }
            }

            summary

            Spacer(minLength: 8)

            if monitor.states.values.contains(where: { $0.status == .needsAuthorization }) {
                Button {
                    Task { await monitor.authorizeKeyUse() }
                } label: {
                    Label("授权密钥监控", systemImage: "touchid")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("这些主机用密钥认证,后台采集需要你先过一次 Touch ID")
            }

            searchField

            Picker(selection: $sortRaw) {
                ForEach(DashboardSort.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .frame(width: 88)
            .help("排序方式")

            Picker(selection: $interval) {
                Text("2 秒").tag(2.0)
                Text("5 秒").tag(5.0)
                Text("10 秒").tag(10.0)
                Text("30 秒").tag(30.0)
                Text("1 分钟").tag(60.0)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .frame(width: 84)
            .help("采集间隔")

            PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "立即刷新")) {
                monitor.refreshAll()
            }

            Menu {
                Text("显示比例")
                Button { cardScale = 1 } label: { scaleMenuLabel("100%", value: 1) }
                Button { cardScale = 1.25 } label: { scaleMenuLabel("125%", value: 1.25) }
                Button { cardScale = 1.5 } label: { scaleMenuLabel("150%", value: 1.5) }
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(String(localized: "仪表盘显示比例"))

            if isEmbedded {
                // 想扔到第二块屏常驻:撕成独立窗口(两边共用同一个采集引擎,不会重复连服务器)
                PanelIconButton(symbol: "macwindow.on.rectangle", help: String(localized: "在新窗口打开")) {
                    SessionManager.shared.isDashboardVisible = false
                    openWindow(id: "dashboard")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func scaleMenuLabel(_ title: String, value: Double) -> some View {
        if cardScale == value {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            let online = monitor.states.values.filter { $0.status == .online }.count
            let offline = monitor.states.values.filter { if case .offline = $0.status { return true }; return false }.count
            let waiting = monitor.states.count - online - offline

            StatusPill(color: .green, text: String(localized: "在线 \(online)"))
            if offline > 0 {
                StatusPill(color: .red, text: String(localized: "离线 \(offline)"))
            }
            if waiting > 0 {
                StatusPill(color: .gray, text: String(localized: "待定 \(waiting)"))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("搜索主机", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 120)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - 网格

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // 同一行里卡片高度不一(离线卡片矮),顶对齐才不会一高一低错开
                columns: [GridItem(
                    .adaptive(minimum: 290 * effectiveCardScale, maximum: 460 * effectiveCardScale),
                    spacing: 12 * effectiveCardScale,
                    alignment: .top
                )],
                spacing: 12 * effectiveCardScale
            ) {
                ForEach(visibleStates) { state in
                    ServerCardView(
                        state: state,
                        theme: theme.current,
                        displayScale: effectiveCardScale,
                        onConnect: { connect(state.id) },
                        onAuthorize: { Task { await monitor.authorizeKeyUse() } }
                    )
                    .contextMenu { cardMenu(state) }
                }
            }
            // 重排一律不动画:实时采样下按指标排序会频繁换位,滑动动画看着像卡片乱跳;
            // 顺带压掉切换排序时菜单收起事务带进来的隐式动画(只有部分卡片跟着动,更乱)
            .animation(nil, value: visibleStates.map(\.id))
            .padding(14 * effectiveCardScale)
        }
    }

    @ViewBuilder
    private func cardMenu(_ state: ServerMonitor.HostState) -> some View {
        Button("连接") { connect(state.id) }
        Button("复制地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(state.address, forType: .string)
        }
        if case .offline(let reason) = state.status {
            Divider()
            Button("复制失败原因") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reason, forType: .string)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("还没有可监控的主机")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("在主窗口侧栏新建主机后,这里会自动开始采集。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    /// 从仪表盘连接:走和侧栏一样的路径(新拨一条连接)。
    /// 不复用监控连接 —— 借用连接的会话不参与自动重连,把它塞给用户的终端并不划算。
    /// 内嵌时开完会话就退回终端(open 会自己关掉仪表盘);独立窗口则把主窗口拉到前面。
    private func connect(_ hostID: UUID) {
        guard let host = allHosts.first(where: { $0.id == hostID }) else { return }
        host.lastConnectedAt = Date()
        SessionManager.shared.open(spec: HostSpec.resolve(host, in: allHosts))
        if !isEmbedded { MainWindowRaiser.raise() }
    }

    private static func comparator(_ sort: DashboardSort) -> (ServerMonitor.HostState, ServerMonitor.HostState) -> Bool {
        switch sort {
        case .name:
            return { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        case .status:
            // 出问题的排前面:仪表盘的意义就是先看见坏消息
            return { rank($0.status) < rank($1.status) }
        case .cpu:
            return { metricRank($0.reading?.cpuFraction) > metricRank($1.reading?.cpuFraction) }
        case .memory:
            return { metricRank($0.reading?.memFraction) > metricRank($1.reading?.memFraction) }
        case .disk:
            return { metricRank($0.reading?.primaryDisk?.fraction) > metricRank($1.reading?.primaryDisk?.fraction) }
        }
    }

    /// 指标量化成 3 个百分点一档再排序:采样间的微小波动(6.01%→6.02%)不该让
    /// 值相近的卡片每个周期都互换位置。排序是稳定的,同档保持既有顺序,只有跨档才移动。
    private static func metricRank(_ fraction: Double?) -> Int {
        guard let fraction else { return .min }
        return Int((fraction * 100 / 3).rounded())
    }

    private static func rank(_ status: ServerMonitor.Status) -> Int {
        switch status {
        case .offline: return 0
        case .needsAuthorization, .needsInteraction: return 1
        case .connecting: return 2
        case .idle: return 3
        case .online: return 4
        }
    }
}

/// 从独立窗口回到主窗口。SwiftUI 的 openWindow 对 WindowGroup 是「再开一个」,
/// 这里要的是把已有的主窗口拉到前面,所以按标记找 NSWindow。
enum MainWindowRaiser {
    static let identifier = NSUserInterfaceItemIdentifier("berth.main")

    static func raise() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
