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
        HStack {
            Text("信息")
                .font(.headline)
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(isLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isLoading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刷新")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(height: AppLayout.topBarHeight)
        .padding(.horizontal, 14)
        .padding(.top, AppLayout.columnTopPadding)
        .padding(.bottom, 8)
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

    @ViewBuilder
    private var serverSection: some View {
        if let info, !info.rows.isEmpty {
            section("服务器") {
                if !info.hostname.isEmpty {
                    infoRow("主机名", info.hostname)
                }
                ForEach(info.rows, id: \.0) { row in
                    infoRow(row.0, row.1)
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
