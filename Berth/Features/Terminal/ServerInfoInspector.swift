import SwiftUI

/// 终端右侧信息面板:连接信息 + 服务器信息 + 端口转发状态(M3 接入)。
struct ServerInfoInspector: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var info: ServerInfo?
    @State private var isLoading = false
    @State private var now = Date()
    @State private var highlightState: HighlightUIState = .idle
    /// 非 zsh 主机:记录检测到的 shell,展示「安装并切换到 zsh」按钮
    @State private var notZshShell: String?
    /// 切换 zsh 成功后提示重连(新登录才用新 shell)
    @State private var offerReconnect = false
    @State private var isAddingForward = false

    private enum HighlightUIState: Equatable { case idle, working, done(String) }

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    forwardsSection
                    if !session.spec.hostname.isEmpty {
                        serverSection
                    }
                    highlightSection
                }
                .padding(14)
            }
        }
        .frame(width: 260)
        .background(theme.panelBackground)
        .onReceive(ticker) { now = $0 }
        .task(id: session.id) { await refresh() }
    }

    private var header: some View {
        PanelHeader(title: String(localized: "信息")) {
            PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "刷新"), spinning: isLoading) {
                Task { await refresh() }
            }
            PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) { onClose() }
        }
    }

    private var connectionSection: some View {
        section(String(localized: "连接")) {
            infoRow(String(localized: "主机"), session.spec.hostname)
            infoRow(String(localized: "端口"), String(session.spec.port))
            infoRow(String(localized: "用户"), session.spec.username)
            infoRow(String(localized: "认证"), authLabel)
            if let connectedAt = session.connectedAt, case .connected = session.state {
                infoRow(String(localized: "已连接"), durationString(from: connectedAt))
            } else {
                infoRow(String(localized: "状态"), stateLabel)
            }
        }
    }

    @ViewBuilder
    private var forwardsSection: some View {
        // 只连接、无任何转发时不显示整段(仅保留一个入口按钮由标题栏承载)
        if !session.spec.forwards.isEmpty || !session.runtimeForwards.isEmpty || isConnected {
            section(String(localized: "端口转发")) {
                ForEach(session.spec.forwards) { forward in
                    forwardRow(forward, removable: false)
                }
                ForEach(session.runtimeForwards) { forward in
                    forwardRow(forward, removable: true)
                }
                if session.spec.forwards.isEmpty && session.runtimeForwards.isEmpty {
                    Text("暂无转发。点右上「+」临时加一条(不落库)。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    isAddingForward = true
                } label: {
                    Label("临时端口转发", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
                .disabled(!isConnected)
                .popover(isPresented: $isAddingForward, arrowEdge: .leading) {
                    AddForwardPopover { spec in
                        session.addRuntimeForward(spec)
                        isAddingForward = false
                    }
                }
            }
        }
    }

    private func forwardRow(_ forward: PortForwardSpec, removable: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(forwardColor(forward.id))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(forward.summary)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(forwardStatusText(forward.id))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if removable {
                Button {
                    session.removeRuntimeForward(forward.id)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("停止这条临时转发")
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    private func forwardColor(_ id: UUID) -> Color {
        switch session.forwardStates[id] {
        case .active: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .none: return .gray
        }
    }

    private func forwardStatusText(_ id: UUID) -> String {
        switch session.forwardStates[id] {
        case .active(let port): return String(localized: "运行中 · 端口 \(String(port))")
        case .starting: return String(localized: "启动中…")
        case .failed(let reason): return reason
        case .none: return String(localized: "未启动")
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        if let info, !info.textRows.isEmpty {
            section(String(localized: "服务器")) {
                if !info.hostname.isEmpty {
                    infoRow(String(localized: "主机名"), info.hostname)
                }
                ForEach(info.textRows, id: \.0) { row in
                    infoRow(row.0, row.1)
                }
            }
            section(String(localized: "资源")) {
                if let memory = info.memoryUsage {
                    meter(
                        label: String(localized: "内存"),
                        fraction: memory.used / memory.total,
                        value: "\(Int(memory.used)) / \(Int(memory.total)) MB"
                    )
                }
                if let diskPercent = info.diskPercent {
                    meter(label: String(localized: "磁盘 /"), fraction: diskPercent, value: info.diskUsage)
                }
                if !info.loadValues.isEmpty {
                    loadMeter(info)
                }
            }
        } else if isLoading {
            section(String(localized: "服务器")) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            section(String(localized: "服务器")) {
                Text(session.state == .connected ? "无法读取服务器信息" : "未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 通用仪表:标签 + 进度条 + 数值,按占用比变色
    private func meter(label: String, fraction: Double, value: String) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.monospacedDigit())
                Text("\(Int(clamped * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(meterColor(clamped))
                    .frame(width: 36, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(meterColor(clamped))
                        .frame(width: max(4, geo.size.width * clamped))
                }
            }
            .frame(height: 6)
        }
    }

    /// 负载:1 分钟负载相对 CPU 核数;下方标注三段负载
    private func loadMeter(_ info: ServerInfo) -> some View {
        let load1 = info.loadValues.first ?? 0
        let cores = max(info.cpuCount, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("负载").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(info.loadValues.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    .font(.caption.monospacedDigit())
                Text("\(cores) 核")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(meterColor(load1 / Double(cores)))
                        .frame(width: max(4, geo.size.width * min(load1 / Double(cores), 1)))
                }
            }
            .frame(height: 6)
        }
    }

    private func meterColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authLabel: String {
        switch session.spec.authMethod {
        case .password: return String(localized: "密码")
        case .privateKeyFile: return String(localized: "私钥文件")
        case .storedKey: return String(localized: "密钥库")
        case .agent: return "ssh-agent"
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle: return String(localized: "空闲")
        case .connecting: return String(localized: "连接中")
        case .connected: return String(localized: "已连接")
        case .disconnected: return String(localized: "已断开")
        }
    }

    private func durationString(from start: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private var highlightSection: some View {
        if case .connected = session.state {
            VStack(alignment: .leading, spacing: 6) {
                Text("增强")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                switch highlightState {
                case .idle:
                    Button {
                        Task {
                            highlightState = .working
                            let result = await session.enableShellHighlight()
                            switch result {
                            case .installed: highlightState = .done(String(localized: "已启用,重开 shell 或执行 source ~/.zshrc 生效"))
                            case .alreadyEnabled: highlightState = .done(String(localized: "此主机已启用命令高亮"))
                            case .notZsh(let shell): notZshShell = shell; highlightState = .idle
                            case .failed(let msg): highlightState = .done(String(localized: "失败:\(msg)"))
                            }
                        }
                    } label: {
                        Label("启用命令高亮", systemImage: "paintbrush.pointed")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        Task {
                            highlightState = .working
                            switch await session.enableCommandIntegration() {
                            case .installed: highlightState = .done(String(localized: "已启用命令集成(退出码/命令边界),重连后生效。"))
                            case .alreadyEnabled: highlightState = .done(String(localized: "命令集成已启用。"))
                            case .failed(let msg): highlightState = .done(String(localized: "失败:\(msg)"))
                            }
                        }
                    } label: {
                        Label("启用命令集成(退出码可见)", systemImage: "checkmark.seal")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let shell = notZshShell {
                        Text("当前登录 shell 是 \(shell),命令高亮仅支持 zsh。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task {
                                highlightState = .working
                                notZshShell = nil
                                switch await session.installAndSwitchToZsh() {
                                case .done, .needsRelogin:
                                    offerReconnect = true
                                    highlightState = .done(String(localized: "已装 zsh 并设为默认 shell + 启用高亮。当前会话仍是旧 shell,重连后生效。"))
                                case .failed(let msg):
                                    highlightState = .done(String(localized: "切换失败:\(msg)"))
                                }
                            }
                        } label: {
                            Label("安装并切换到 zsh", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Text("在此服务器安装 zsh-syntax-highlighting,输入命令实时染色")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                case .working:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("安装中…").font(.caption).foregroundStyle(.secondary)
                    }
                case .done(let msg):
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if offerReconnect {
                        Button {
                            offerReconnect = false
                            highlightState = .idle
                            Task {
                                session.disconnect()
                                try? await Task.sleep(for: .milliseconds(300))
                                session.connect()
                            }
                        } label: {
                            Label("立即重连生效", systemImage: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard case .connected = session.state else {
            info = nil
            return
        }
        // 切标签时先清空,避免网络往返期间展示上一台主机的数据
        info = nil
        isLoading = true
        let fetched = await session.fetchServerInfo()
        // .task(id:) 切换会取消旧任务;若 fetch 不响应取消而迟到返回,不能把旧主机数据写到新标签上
        guard !Task.isCancelled else { return }
        info = fetched
        isLoading = false
    }
}
