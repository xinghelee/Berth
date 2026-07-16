import SwiftUI

/// 终端区底部状态栏:连接状态点 + user@host + 连接时长 + 端口转发 | CPU/内存(5s 轮询)+ 本地时钟 + 终端行列数。
/// 跟随当前选中会话,时钟与时长每秒刷新。
struct StatusBarView: View {
    let session: TerminalSession

    /// 服务器资源快照(每 5s 经 exec 通道拉取,与 PTY 并存)
    @State private var stats: ServerInfo?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(addressText)
                    .foregroundStyle(.secondary)
                Text(stateText(now: context.date))
                    .foregroundStyle(.tertiary)
                if !session.forwardStates.isEmpty {
                    separatorDot
                    Text(forwardText)
                        .foregroundStyle(forwardAllActive ? .secondary : Color.yellow)
                        .help("端口转发状态(详见 ⌘I 信息面板)")
                }

                Spacer()

                if isConnected, let stats {
                    if let cpuText = cpuText(stats) {
                        Text(cpuText)
                            .foregroundStyle(.secondary)
                            .help("1 分钟负载 / 核数(\(stats.load)\(stats.cpuCount > 0 ? " · \(stats.cpuCount) 核" : ""))")
                        separatorDot
                    }
                    if let memText = memText(stats) {
                        Text(memText)
                            .foregroundStyle(.secondary)
                            .help("服务器内存占用(\(stats.memory))")
                        separatorDot
                    }
                }
                Text(context.date.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.tertiary)
                separatorDot
                Text("\(session.terminalView.getTerminal().cols)×\(session.terminalView.getTerminal().rows)")
                    .foregroundStyle(.tertiary)
                    .help("终端列数 × 行数")
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(theme.elevatedBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 1)
            }
        }
        .padding(.bottom, 6)
        .task(id: session.id) {
            // 资源轮询:连接中每 5s 拉一次;断开时清空,避免残留旧数据
            while !Task.isCancelled {
                if isConnected {
                    let fetched = await session.fetchServerInfo()
                    guard !Task.isCancelled else { return }
                    stats = fetched
                } else {
                    stats = nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var separatorDot: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private var isConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    private var addressText: String {
        let port = session.spec.port == 22 ? "" : ":\(session.spec.port)"
        return "\(session.spec.username)@\(session.spec.hostname)\(port)"
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

    private func stateText(now: Date) -> String {
        switch session.state {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected:
            guard let start = session.connectedAt else { return "已连接" }
            return "已连接 " + durationString(from: start, to: now)
        case .disconnected(let reason):
            return reason == .userInitiated ? "已断开" : "连接断开"
        }
    }

    /// 1 分钟负载换算核占比;取不到核数时直接显示负载值
    private func cpuText(_ info: ServerInfo) -> String? {
        guard let load1 = info.loadValues.first else { return nil }
        if info.cpuCount > 0 {
            return "CPU \(Int((load1 / Double(info.cpuCount) * 100).rounded()))%"
        }
        return String(format: "负载 %.2f", load1)
    }

    private func memText(_ info: ServerInfo) -> String? {
        guard let usage = info.memoryUsage, usage.total > 0 else { return nil }
        return "内存 \(Int((usage.used / usage.total * 100).rounded()))%"
    }

    private var forwardAllActive: Bool {
        session.forwardStates.values.allSatisfy {
            if case .active = $0 { return true }
            return false
        }
    }

    private var forwardText: String {
        let active = session.forwardStates.values.filter {
            if case .active = $0 { return true }
            return false
        }.count
        return "转发 \(active)/\(session.forwardStates.count)"
    }

    private func durationString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
