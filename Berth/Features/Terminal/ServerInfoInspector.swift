import SwiftUI

/// 终端右侧信息面板:连接信息 + 服务器信息 + 端口转发状态(M3 接入)。
struct ServerInfoInspector: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var info: ServerInfo?
    @State private var isLoading = false
    @State private var now = Date()

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    if !session.spec.forwards.isEmpty {
                        forwardsSection
                    }
                    if !session.spec.hostname.isEmpty {
                        serverSection
                    }
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
        PanelHeader(title: "信息") {
            PanelIconButton(symbol: "arrow.clockwise", help: "刷新", spinning: isLoading) {
                Task { await refresh() }
            }
            PanelIconButton(symbol: "xmark", help: "关闭") { onClose() }
        }
    }

    private var connectionSection: some View {
        section("连接") {
            infoRow("主机", session.spec.hostname)
            infoRow("端口", String(session.spec.port))
            infoRow("用户", session.spec.username)
            infoRow("认证", authLabel)
            if let connectedAt = session.connectedAt, case .connected = session.state {
                infoRow("已连接", durationString(from: connectedAt))
            } else {
                infoRow("状态", stateLabel)
            }
        }
    }

    private var forwardsSection: some View {
        section("端口转发") {
            ForEach(session.spec.forwards) { forward in
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
                }
            }
        }
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
        case .active(let port): return "运行中 · 端口 \(port)"
        case .starting: return "启动中…"
        case .failed(let reason): return reason
        case .none: return "未启动"
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        if let info, !info.textRows.isEmpty {
            section("服务器") {
                if !info.hostname.isEmpty {
                    infoRow("主机名", info.hostname)
                }
                ForEach(info.textRows, id: \.0) { row in
                    infoRow(row.0, row.1)
                }
            }
            section("资源") {
                if let memory = info.memoryUsage {
                    meter(
                        label: "内存",
                        fraction: memory.used / memory.total,
                        value: "\(Int(memory.used)) / \(Int(memory.total)) MB"
                    )
                }
                if let diskPercent = info.diskPercent {
                    meter(label: "磁盘 /", fraction: diskPercent, value: info.diskUsage)
                }
                if !info.loadValues.isEmpty {
                    loadMeter(info)
                }
            }
        } else if isLoading {
            section("服务器") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            section("服务器") {
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
        case .password: return "密码"
        case .privateKeyFile: return "私钥文件"
        case .storedKey: return "密钥库"
        case .agent: return "ssh-agent"
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle: return "空闲"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnected: return "已断开"
        }
    }

    private func durationString(from start: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func refresh() async {
        guard case .connected = session.state else {
            info = nil
            return
        }
        isLoading = true
        info = await session.fetchServerInfo()
        isLoading = false
    }
}
