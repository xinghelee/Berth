import SwiftUI

/// 终端区底部状态栏:连接状态点 + user@host + 连接时长 + 端口转发状态 | 右侧终端行列数。
/// 跟随当前选中会话,每秒随时长刷新。
struct StatusBarView: View {
    let session: TerminalSession

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
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(forwardText)
                        .foregroundStyle(forwardAllActive ? .secondary : Color.yellow)
                        .help("端口转发状态(详见 ⌘I 信息面板)")
                }
                Spacer()
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
