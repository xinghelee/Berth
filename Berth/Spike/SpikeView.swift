import SwiftUI

/// M0 spike 界面:顶部连接表单 + 终端区 + 底部状态栏。
/// 支持通过启动参数自动连接,便于自动化验证:
///   --host <h> --port <p> --user <u> --password <pw> [--key <path> --passphrase <pp>] --connect [--send "<cmd>"]
struct SpikeView: View {
    @StateObject private var session = SpikeSession()

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authKind: AuthKind = .password
    @State private var password = ""
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var passphrase = ""
    @State private var autoSendCommand: String?
    @State private var autoTestDumpPath: String?

    enum AuthKind: String, CaseIterable, Identifiable {
        case password = "密码"
        case privateKey = "私钥"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionForm
                .padding(10)
            Divider()
            TerminalHostView(terminalView: session.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(Color(nsColor: NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)))
        .onAppear(perform: applyLaunchArguments)
        .onChange(of: session.phase) { _, newPhase in
            if newPhase == .connected, let command = autoSendCommand {
                autoSendCommand = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.sendText(command + "\n")
                }
            }
            if newPhase == .connected, let dumpPath = autoTestDumpPath {
                autoTestDumpPath = nil
                session.runAutoTest(dumpPath: dumpPath)
            }
        }
    }

    private var isBusy: Bool {
        switch session.phase {
        case .connecting, .connected: return true
        default: return false
        }
    }

    private var connectionForm: some View {
        HStack(spacing: 8) {
            TextField("主机", text: $host)
                .frame(minWidth: 140)
            TextField("端口", text: $port)
                .frame(width: 60)
            TextField("用户名", text: $username)
                .frame(width: 100)
            Picker("", selection: $authKind) {
                ForEach(AuthKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .frame(width: 90)

            if authKind == .password {
                SecureField("密码", text: $password)
                    .frame(minWidth: 120)
            } else {
                TextField("私钥路径", text: $keyPath)
                    .frame(minWidth: 160)
                SecureField("passphrase(可选)", text: $passphrase)
                    .frame(minWidth: 120)
            }

            if isBusy {
                Button("断开") { session.disconnect() }
            } else {
                Button("连接") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(isBusy)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    private var statusText: String {
        switch session.phase {
        case .idle: return "未连接"
        case .connecting(let detail): return detail
        case .connected: return "已连接"
        case .disconnected: return "连接已断开"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .idle, .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    private func connect() {
        let auth: SpikeSession.Auth = authKind == .password
            ? .password(password)
            : .privateKey(path: keyPath, passphrase: passphrase.isEmpty ? nil : passphrase)
        session.connect(
            host: host,
            port: Int(port) ?? 22,
            username: username,
            auth: auth
        )
    }

    // MARK: - 启动参数(自动化验证用)

    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }

        if let value = value(after: "--host") { host = value }
        if let value = value(after: "--port") { port = value }
        if let value = value(after: "--user") { username = value }
        if let value = value(after: "--password") {
            password = value
            authKind = .password
        }
        if let value = value(after: "--key") {
            keyPath = value
            authKind = .privateKey
        }
        if let value = value(after: "--passphrase") { passphrase = value }
        if let value = value(after: "--send") { autoSendCommand = value }
        if let value = value(after: "--autotest") {
            autoTestDumpPath = value
            session.debugLogPath = value + ".log"
        }
        if args.contains("--connect") {
            connect()
        }
    }
}
