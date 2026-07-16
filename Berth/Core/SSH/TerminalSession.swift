import AppKit
import Citadel
import Crypto
import Foundation
import LocalAuthentication
import NIOCore
import NIOSSH
import Observation
import SwiftTerm

/// 单个 SSH 终端会话:状态机 idle → connecting → connected → disconnected(reason)。
/// UI 只订阅 `state`,不直接操作连接。TerminalView 由会话持有,
/// 断线后手动重连复用同一视图,scrollback 自然保留。
///
/// 注:规格中的 authenticating 状态并入 connecting(detail:) —— Citadel 的
/// connect 将 TCP/密钥交换/认证合并为单次调用,M2 若需要细分再挂通道事件。
@MainActor
@Observable
final class TerminalSession: Identifiable {

    enum State: Equatable {
        case idle
        case connecting(detail: String)
        case connected
        case disconnected(DisconnectReason)
    }

    enum DisconnectReason: Equatable {
        case userInitiated
        case remoteClosed
        case error(String)

        var message: String? {
            switch self {
            case .userInitiated: return nil
            case .remoteClosed: return "连接已被服务器关闭"
            case .error(let text): return text
            }
        }
    }

    enum SessionError: LocalizedError {
        case unsupportedKey
        case missingStoredKey
        case authenticationGateFailed
        case notConnected

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。"
            case .missingStoredKey:
                return "找不到该主机引用的密钥,请在「密钥」页检查或重新选择。"
            case .authenticationGateFailed:
                return "身份验证未通过,已取消连接。可在设置中关闭「使用密钥前要求 Touch ID」。"
            case .notConnected:
                return "未连接,无法打开 SFTP。"
            }
        }
    }

    let id = UUID()
    let spec: HostSpec
    let terminalView: TerminalView

    private(set) var state: State = .idle
    /// 最近一次连接建立的时间(用于 inspector 显示连接时长)
    private(set) var connectedAt: Date?
    /// 端口转发运行态(inspector 展示,可单独开关)
    private(set) var forwardStates: [UUID: PortForwardService.ForwardState] = [:]
    /// 等待用户决策的主机密钥确认(首次连接指纹 / 密钥变更警告)
    var hostKeyPrompt: HostKeyPrompt?
    /// 自动重连:当前第几次尝试、是否已排定下一次
    private(set) var reconnectAttempt = 0
    private(set) var isAutoReconnectScheduled = false

    @ObservationIgnored private var client: SSHClient?
    /// 本会话当前所用连接的共享持有者(自建或借用);断开时 release,引用归零才真正关闭
    @ObservationIgnored private(set) var connection: SSHConnection?
    /// 待借用的连接(⌘T 复制 / 分屏 同主机时由 SessionManager 注入);一次性,消费后清空
    @ObservationIgnored private var willBorrow: SSHConnection?
    /// 本次运行是否走了借用路径(借用会话不自动重连,避免网络抖动时多会话各自新建 TCP 造成连接风暴)
    @ObservationIgnored private var isBorrower = false
    /// 跳板链上的中间 client,必须保活以维持隧道;所有权在建立后转入 SSHConnection
    @ObservationIgnored private var jumpClients: [SSHClient] = []
    @ObservationIgnored private var forwardService: PortForwardService?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var stdinWriter: AsyncStream<StdinEvent>.Continuation?
    @ObservationIgnored private var userInitiatedDisconnect = false
    @ObservationIgnored private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// 只有成功连上过的会话才自动重连(认证失败/密钥被拒不重试)
    @ObservationIgnored private var everConnected = false
    /// 临时直连/自动化验收用:绕过 Keychain 的一次性凭据(不落任何持久化)
    @ObservationIgnored var transientPassword: String?
    @ObservationIgnored var transientPassphrase: String?

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    init(spec: HostSpec) {
        self.spec = spec
        let fontSize = CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        ThemeStore.shared.apply(to: terminalView)
        CursorPrefs.apply(to: terminalView)
        terminalView.terminalDelegate = self
    }

    // MARK: - 连接复用

    /// 已连上时对外暴露本会话所用连接,供 SessionManager 让新会话(⌘T/分屏)复用。
    var liveConnection: SSHConnection? {
        guard case .connected = state else { return nil }
        return connection
    }

    /// 注入一条待复用的连接(一次性,仅对下一次 connect 生效)。同主机复用时避免新建 TCP。
    func prepareToBorrow(_ connection: SSHConnection) {
        willBorrow = connection
    }

    // MARK: - 生命周期

    /// 可重入:disconnected 后再次调用即手动重连
    func connect() {
        guard sessionTask == nil else { return }
        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
        state = .connecting(detail: "正在连接 \(spec.hostname):\(spec.port)…")

        sessionTask = Task {
            var disconnectReason: DisconnectReason
            do {
                try await runSession()
                disconnectReason = userInitiatedDisconnect ? .userInitiated : .remoteClosed
            } catch is CancellationError {
                disconnectReason = .userInitiated
            } catch {
                disconnectReason = userInitiatedDisconnect
                    ? .userInitiated
                    : .error(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port))
            }
            state = .disconnected(disconnectReason)
            stopPortForwards()
            stdinWriter?.finish()
            stdinWriter = nil
            let releasing = self.connection
            // 连接建立中途失败(如跳板链某一跳出错)时,已连上的跳板还没转入 SSHConnection,
            // 留在 jumpClients 里,须在此关闭,否则泄漏半开连接(还会占满服务器 MaxStartups)
            let orphanedJumps = self.jumpClients
            self.client = nil
            self.connection = nil
            self.jumpClients = []
            sessionTask = nil
            if !orphanedJumps.isEmpty {
                Task.detached {
                    for jump in orphanedJumps.reversed() { try? await jump.close() }
                }
            }
            // 引用归零才真正关闭底层连接/跳板;借用会话的 release 不会误关共享连接
            releasing?.release()
            maybeScheduleReconnect(after: disconnectReason)
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
        // 取消会话任务即结束 PTY 循环 → withPTY 只关自己的通道 → teardown 里 release 连接。
        // 不在此直接关 client:共享连接时会误伤其它复用会话(分屏/⌘T)。
        sessionTask?.cancel()
    }

    // MARK: - 自动重连(指数退避,保留 scrollback)

    func cancelAutoReconnect() {
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
    }

    private func maybeScheduleReconnect(after reason: DisconnectReason) {
        guard reason != .userInitiated, everConnected else { return }
        // 借用会话不自动重连:否则共享连接因网络抖动断开时,拥有者与所有分屏/复制会话会
        // 同时各自新建 TCP,形成连接风暴,反而触发服务器的频率惩罚。拥有者正常重连(仅 1 条),
        // 借用会话保持断线,由用户手动「立即重连」(此时走自建连接,单条,不成风暴)。
        guard !isBorrower else { return }
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.autoReconnect) as? Bool ?? true
        guard enabled, reconnectAttempt < 8 else { return }

        reconnectAttempt += 1
        isAutoReconnectScheduled = true
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard case .disconnected = self.state, self.isAutoReconnectScheduled else { return }
            self.isAutoReconnectScheduled = false
            self.connect()
        }
    }

    // MARK: - 主机密钥决策(known_hosts)

    /// UI 回填用户决定;未决时关闭弹窗按拒绝处理(幂等)
    func resolveHostKeyPrompt(accepted: Bool) {
        hostKeyPrompt = nil
        hostKeyContinuation?.resume(returning: accepted)
        hostKeyContinuation = nil
    }

    private func requestHostKeyDecision(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // 理论上不会并发出现两个决策请求;保守起见拒绝旧的
                self.hostKeyContinuation?.resume(returning: false)
                self.hostKeyContinuation = continuation
                self.hostKeyPrompt = prompt
                self.state = .connecting(detail: "等待主机密钥确认…")
            }
        }
    }

    /// 关闭标签页时调用:断开并放弃会话
    func shutdown() {
        disconnect()
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
    }

    /// inspector 用:在同一连接上另开通道跑一条命令取服务器信息(不影响 PTY)。
    /// 命令保证 exit 0 且不写 stderr,避免 Citadel executeCommand 抛错。
    func fetchServerInfo() async -> ServerInfo? {
        guard let client else { return nil }
        let script = """
        printf 'HOSTNAME=%s\\n' "$(hostname 2>/dev/null)"
        printf 'KERNEL=%s\\n' "$(uname -sr 2>/dev/null)"
        printf 'OS=%s\\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
        printf 'UPTIME=%s\\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
        printf 'LOAD=%s\\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        printf 'CPUS=%s\\n' "$(nproc 2>/dev/null)"
        printf 'MEM=%s\\n' "$(free -m 2>/dev/null | awk '/Mem:/{print $3\"/\"$2\" MB\"}')"
        printf 'DISK=%s\\n' "$(df -h / 2>/dev/null | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}')"
        """
        do {
            let buffer = try await client.executeCommand("sh -c \(shellQuote(script))")
            let text = String(buffer: buffer)
            return ServerInfo(parsing: text)
        } catch {
            return nil
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func focusTerminal() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// 在当前连接上开一个 SFTP 子通道(与 PTY 并存,复用同一 SSHClient)
    func openSFTP() async throws -> SFTPClient {
        guard let client else { throw SessionError.notConnected }
        return try await client.openSFTP()
    }

    // MARK: - 端口转发

    private func startPortForwards() {
        guard let client, !spec.forwards.isEmpty else { return }
        forwardStates = Dictionary(uniqueKeysWithValues: spec.forwards.map { ($0.id, .starting) })
        let service = PortForwardService(client: client) { [weak self] id, state in
            Task { @MainActor in self?.forwardStates[id] = state }
        }
        forwardService = service
        service.start(spec.forwards)
    }

    private func stopPortForwards() {
        forwardService?.stopAll()
        forwardService = nil
        forwardStates = [:]
    }

    // MARK: - 连接实现

    /// 建立到目标主机的 SSHClient:无跳板则直连;有跳板则连最外层跳板后逐跳 jump。
    /// 中间跳板的 client 必须保活(隧道依赖它),存入 jumpClients。
    private func establishClient() async throws -> SSHClient {
        guard !spec.jump.isEmpty else {
            return try await connectEntry(to: spec, useTransient: true)
        }

        // 连最外层跳板
        let first = spec.jump[0]
        state = .connecting(detail: "正在连接跳板机 \(first.hostname):\(first.port)…")
        var current = try await connectEntry(to: first, useTransient: false)
        jumpClients.append(current)

        // 逐跳 jump 到后续跳板
        for hop in spec.jump.dropFirst() {
            state = .connecting(detail: "经跳板机 → \(hop.hostname):\(hop.port)…")
            current = try await current.jump(to: try settings(for: hop, useTransient: false))
            jumpClients.append(current)
        }

        // 最后 jump 到目标本机
        state = .connecting(detail: "经跳板机 → \(spec.hostname):\(spec.port)…")
        return try await current.jump(to: try settings(for: spec, useTransient: true))
    }

    /// 最外层 TCP 连接:若配了代理,先经代理再交给 Citadel;否则直连。
    private func connectEntry(to hop: HostSpec, useTransient: Bool) async throws -> SSHClient {
        let clientSettings = try settings(for: hop, useTransient: useTransient)
        guard spec.proxy.isEnabled else {
            return try await SSHClient.connect(to: clientSettings)
        }
        state = .connecting(detail: "经代理 \(spec.proxy.host):\(spec.proxy.port) 连接 \(hop.hostname):\(hop.port)…")
        let proxyPassword = spec.proxy.requiresAuth
            ? try KeychainStore.read(account: KeychainStore.proxyPasswordAccount(for: spec.hostID))
            : nil
        let channel = try await ProxyConnector.connect(
            through: spec.proxy,
            proxyPassword: proxyPassword,
            to: hop.hostname,
            port: hop.port
        )
        return try await SSHClient.connect(on: channel, settings: clientSettings)
    }

    private func runSession() async throws {
        let client: SSHClient
        let connection: SSHConnection
        if let borrow = willBorrow, borrow.isAlive {
            // 借用已建立的连接:跳过 TCP/密钥交换/认证/主机密钥/Touch ID,直接在其上开 PTY 通道
            isBorrower = true
            willBorrow = nil
            borrow.retain()
            connection = borrow
            client = borrow.client
            state = .connecting(detail: "复用现有连接,正在打开终端通道…")
        } else {
            isBorrower = false
            willBorrow = nil
            // 目标或任一跳板用密钥时,连接前统一过一次 Touch ID(避免链路上多次弹窗)
            let usesKeys = ([spec] + spec.jump).contains { $0.authMethod != .password }
            if usesKeys { try await requireTouchIDIfEnabled() }
            let established = try await establishClient()
            // 跳板链所有权转入 SSHConnection,由引用计数统一管理关闭
            connection = SSHConnection(client: established, jumpClients: jumpClients)
            jumpClients = []
            connection.retain()
            client = established
            state = .connecting(detail: "认证成功,正在打开终端通道…")
        }
        self.client = client
        self.connection = connection

        let term = terminalView.getTerminal()
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: term.cols,
            terminalRowHeight: term.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )

        try await client.withPTY(ptyRequest) { inbound, outbound in
            let (stream, continuation) = AsyncStream.makeStream(of: StdinEvent.self)
            await MainActor.run {
                self.stdinWriter = continuation
                self.state = .connected
                self.connectedAt = Date()
                self.everConnected = true
                self.reconnectAttempt = 0
                self.focusTerminal()
                // 端口转发绑在连接层:仅拥有者建立,借用会话复用同一连接不重复绑定
                if !self.isBorrower { self.startPortForwards() }
            }

            // 单一消费者串行写入,保证按键与 resize 的顺序
            let stdinPump = Task {
                for await event in stream {
                    switch event {
                    case .bytes(let bytes):
                        try await outbound.write(ByteBuffer(bytes: bytes))
                    case .resize(let cols, let rows):
                        try await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                    }
                }
            }
            defer { stdinPump.cancel() }

            for try await chunk in inbound {
                let buffer: ByteBuffer
                switch chunk {
                case .stdout(let b), .stderr(let b):
                    buffer = b
                }
                let bytes = Array(buffer.readableBytesView)
                await MainActor.run {
                    self.terminalView.feed(byteArray: bytes[...])
                }
            }
        }
    }

    /// 为某一跳(目标或跳板)构建认证方式。凭据按该跳自己的 hostID 从 Keychain 解析;
    /// useTransient 仅对目标本机成立(临时直连时用户当场输入的密码/passphrase)。
    private func authenticationMethod(for hop: HostSpec, useTransient: Bool) throws -> SSHAuthenticationMethod {
        let transientPW = useTransient ? transientPassword : nil
        let transientPP = useTransient ? transientPassphrase : nil
        switch hop.authMethod {
        case .password:
            let password = try transientPW
                ?? KeychainStore.read(account: KeychainStore.passwordAccount(for: hop.hostID))
                ?? ""
            return .passwordBased(username: hop.username, password: password)

        case .privateKeyFile:
            guard let path = hop.privateKeyPath, !path.isEmpty else { throw SessionError.unsupportedKey }
            let expanded = NSString(string: path).expandingTildeInPath
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let passphrase = try transientPP
                ?? KeychainStore.read(account: KeychainStore.passphraseAccount(for: hop.hostID))
            return try Self.keyAuthentication(username: hop.username, keyText: keyText, passphrase: passphrase)

        case .storedKey:
            guard let keyID = hop.keyID,
                  let material = try KeychainStore.read(account: KeychainStore.privateKeyAccount(for: keyID)) else {
                throw SessionError.missingStoredKey
            }
            // 生成的密钥存 raw ed25519(base64 32 字节);导入的存 OpenSSH PEM
            if let raw = Data(base64Encoded: material), raw.count == 32,
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: hop.username, privateKey: key)
            }
            let passphrase = try KeychainStore.read(account: KeychainStore.keyPassphraseAccount(for: keyID))
            return try Self.keyAuthentication(username: hop.username, keyText: material, passphrase: passphrase)

        case .agent:
            guard let agent = SSHAgentClient.fromEnvironment() else { throw AgentAuthError.noAgent }
            let identities = (try? agent.listIdentities()) ?? []
            let delegate = AgentAuthDelegate(username: hop.username, agent: agent, identities: identities)
            guard delegate.hasUsableKeys else { throw AgentAuthError.noIdentities }
            return .custom(delegate)
        }
    }

    private func hostKeyValidator(for hop: HostSpec) -> SSHHostKeyValidator {
        let validator = InteractiveHostKeyValidator(hostname: hop.hostname, port: hop.port) { [weak self] prompt in
            guard let self else { return false }
            return await self.requestHostKeyDecision(prompt)
        }
        return .custom(validator)
    }

    private func settings(for hop: HostSpec, useTransient: Bool) throws -> SSHClientSettings {
        let method = try authenticationMethod(for: hop, useTransient: useTransient)
        return SSHClientSettings(
            host: hop.hostname,
            port: hop.port,
            authenticationMethod: { method },
            hostKeyValidator: hostKeyValidator(for: hop)
        )
    }

    private static func keyAuthentication(username: String, keyText: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
            return .ed25519(username: username, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
            return .rsa(username: username, privateKey: key)
        }
        throw SessionError.unsupportedKey
    }

    /// 规格 5.4:读取私钥用于连接前可要求 Touch ID(设置项,默认开)
    private func requireTouchIDIfEnabled() async throws {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.requireTouchIDForKeys) as? Bool ?? true
        guard enabled else { return }
        state = .connecting(detail: "等待身份验证(Touch ID)…")
        let context = LAContext()
        do {
            // deviceOwnerAuthentication:优先生物识别,失败回退登录密码
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "使用私钥连接 \(spec.label)")
        } catch {
            throw SessionError.authenticationGateFailed
        }
    }
}

// MARK: - TerminalViewDelegate(AppKit 主线程回调)

extension TerminalSession: TerminalViewDelegate {

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            _ = stdinWriter?.yield(.bytes(bytes))
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            _ = stdinWriter?.yield(.resize(cols: newCols, rows: newRows))
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
