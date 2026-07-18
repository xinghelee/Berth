import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// iOS 终端会话:跳板链/代理/端口转发 + 密码/密钥库认证 + PTY 流。
/// 与 Mac 端 TerminalSession 同构(不含分屏借用、Touch ID 门槛、本地 agent)。
@MainActor
@Observable
final class IOSTerminalSession {
    enum State: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
        /// 密码认证但本设备没有该主机的密码(同步过来的主机首次在本机使用)——引导补录
        case needsPassword
        case closed
    }

    enum IOSSessionError: LocalizedError {
        case unsupportedAuth(String)
        case missingStoredKey
        case unsupportedKey
        case needsPassword

        var errorDescription: String? {
            switch self {
            case .needsPassword: return String(localized: "请输入此主机的密码")
            case .unsupportedAuth(let name): return String(localized: "iOS 版暂不支持「\(name)」认证方式")
            case .missingStoredKey: return String(localized: "找不到该主机引用的密钥,请在「密钥」页检查或重新选择。")
            case .unsupportedKey: return String(localized: "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。")
            }
        }
    }

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    private(set) var state: State = .idle
    /// 首连/变更时等待用户决策的主机密钥信息
    var hostKeyPrompt: HostKeyPrompt?
    /// 端口转发状态(信息面板展示)
    private(set) var forwardStates: [UUID: PortForwardService.ForwardState] = [:]
    private(set) var connectedAt: Date?

    /// 服务器输出回调(主线程),由终端视图订阅并 feed
    var onOutput: (([UInt8]) -> Void)?

    let spec: HostSpec
    /// 快速直连时用户当场输入的密码(只对目标本机生效,不落库)
    var transientPassword: String?
    private(set) var client: SSHClient?
    private var jumpClients: [SSHClient] = []
    private var forwardService: PortForwardService?
    private var sessionTask: Task<Void, Never>?
    private var stdinWriter: AsyncStream<StdinEvent>.Continuation?
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    private var lastCols = 80
    private var lastRows = 24

    init(spec: HostSpec) {
        self.spec = spec
    }

    var title: String { spec.label }
    var subtitle: String { "\(spec.username)@\(spec.hostname)" }

    func start(cols: Int, rows: Int) {
        lastCols = max(cols, 20); lastRows = max(rows, 5)
        guard sessionTask == nil else { return }
        sessionTask = Task { await run(cols: lastCols, rows: lastRows) }
    }

    func send(_ data: ArraySlice<UInt8>) {
        stdinWriter?.yield(.bytes(Array(data)))
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
    }

    func resize(cols: Int, rows: Int) {
        lastCols = max(cols, 20); lastRows = max(rows, 5)
        stdinWriter?.yield(.resize(cols: cols, rows: rows))
    }

    func close() {
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter?.finish()
        teardown()
        if case .failed = state {} else { state = .closed }
    }

    /// 主机密钥弹窗的用户决策回传
    func resolveHostKey(trusted: Bool) {
        hostKeyPrompt = nil
        hostKeyContinuation?.resume(returning: trusted)
        hostKeyContinuation = nil
    }

    /// 补录密码后重连;save 时同时写入(可同步)钥匙串,之后本机及其它设备免再输
    func providePassword(_ password: String, save: Bool) {
        transientPassword = password
        if save {
            try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: spec.hostID))
        }
        sessionTask?.cancel()
        sessionTask = nil
        teardown()
        connectedAt = nil
        sessionTask = Task { await run(cols: lastCols, rows: lastRows) }
    }

    // MARK: - 连接主流程

    private func run(cols: Int, rows: Int) async {
        state = .connecting(String(localized: "正在连接 \(spec.hostname):\(String(spec.port))…"))
        do {
            let client = try await establishClient()
            self.client = client
            state = .connecting(String(localized: "认证成功,正在打开终端通道…"))

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
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
                    self.startPortForwards()
                }

                // 连接后自动执行命令(逐行发送,自动补回车)
                let startup = self.spec.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines)
                if !startup.isEmpty {
                    try? await Task.sleep(for: .milliseconds(400))
                    for line in startup.split(whereSeparator: \.isNewline) {
                        let cmd = line.trimmingCharacters(in: .whitespaces)
                        guard !cmd.isEmpty else { continue }
                        try? await outbound.write(ByteBuffer(bytes: Array((cmd + "\n").utf8)))
                        try? await Task.sleep(for: .milliseconds(120))
                    }
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
                    await MainActor.run { self.onOutput?(bytes) }
                }
            }
            state = .failed(String(localized: "连接已被服务器关闭"))
        } catch is CancellationError {
            state = .closed
        } catch IOSSessionError.needsPassword {
            state = .needsPassword
        } catch let error as IOSSessionError {
            state = .failed(error.localizedDescription)
        } catch let error as HostKeyError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port, authMethod: spec.authMethod))
        }
        teardown()
    }

    private func teardown() {
        stopPortForwards()
        let client = self.client
        let jumps = jumpClients
        self.client = nil
        jumpClients = []
        Task.detached {
            try? await client?.close()
            for jump in jumps.reversed() {
                try? await jump.close()
            }
        }
    }

    // MARK: - 连接链(与 Mac 端 establishClient 同构)

    /// 无跳板则直连;有跳板则连最外层跳板后逐跳 jump。中间 client 保活于 jumpClients。
    private func establishClient() async throws -> SSHClient {
        guard !spec.jump.isEmpty else {
            return try await connectEntry(to: spec)
        }

        let first = spec.jump[0]
        state = .connecting(String(localized: "正在连接跳板机 \(first.hostname):\(String(first.port))…"))
        var current = try await connectEntry(to: first)
        jumpClients.append(current)

        for hop in spec.jump.dropFirst() {
            state = .connecting(String(localized: "经跳板机 → \(hop.hostname):\(String(hop.port))…"))
            current = try await current.jump(to: try settings(for: hop))
            jumpClients.append(current)
        }

        state = .connecting(String(localized: "经跳板机 → \(spec.hostname):\(String(spec.port))…"))
        return try await current.jump(to: try settings(for: spec))
    }

    /// 最外层 TCP 连接:若配了代理,先经代理再交给 Citadel;否则直连。
    private func connectEntry(to hop: HostSpec) async throws -> SSHClient {
        let clientSettings = try settings(for: hop)
        guard spec.proxy.isEnabled else {
            return try await SSHClient.connect(to: clientSettings)
        }
        state = .connecting(String(localized: "经代理 \(spec.proxy.host):\(String(spec.proxy.port)) 连接 \(hop.hostname):\(String(hop.port))…"))
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

    private func settings(for hop: HostSpec) throws -> SSHClientSettings {
        let method = try authenticationMethod(for: hop)
        let validator = InteractiveHostKeyValidator(
            hostname: hop.hostname, port: hop.port, autoTrustUnknown: true
        ) { [weak self] prompt in
            guard let self else { return false }
            return await self.requestHostKeyDecision(prompt)
        }
        return SSHClientSettings(
            host: hop.hostname,
            port: hop.port,
            authenticationMethod: { method },
            hostKeyValidator: .custom(validator)
        )
    }

    private func requestHostKeyDecision(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyContinuation = continuation
            hostKeyPrompt = prompt
        }
    }

    // MARK: - 服务器信息(与 Mac 端 fetchServerInfo 同构)

    /// 在同一连接上另开通道跑一条命令取服务器信息(不影响 PTY)。
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
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            let buffer = try await client.executeCommand("sh -c \(quoted)")
            return ServerInfo(parsing: String(buffer: buffer))
        } catch {
            return nil
        }
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

    // MARK: - 认证(密码 / 密钥库;文件路径与 agent 在 iOS 上不可用)

    private func authenticationMethod(for hop: HostSpec) throws -> SSHAuthenticationMethod {
        switch hop.authMethod {
        case .password:
            let password = try (hop.hostID == spec.hostID ? transientPassword : nil)
                ?? KeychainStore.read(account: KeychainStore.passwordAccount(for: hop.hostID))
            // 目标本机无密码(常见于同步过来但没在本机补录过):引导输入,而非拿空密码撞失败
            guard let password else {
                if hop.hostID == spec.hostID { throw IOSSessionError.needsPassword }
                return .passwordBased(username: hop.username, password: "")
            }
            return .passwordBased(username: hop.username, password: password)

        case .storedKey:
            guard let keyID = hop.keyID,
                  let material = try KeychainStore.read(account: KeychainStore.privateKeyAccount(for: keyID)) else {
                throw IOSSessionError.missingStoredKey
            }
            if let raw = Data(base64Encoded: material), raw.count == 32,
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: hop.username, privateKey: key)
            }
            let passphrase = try KeychainStore.read(account: KeychainStore.keyPassphraseAccount(for: keyID))
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: material, decryptionKey: decryptionKey) {
                return .ed25519(username: hop.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: material, decryptionKey: decryptionKey) {
                return .rsa(username: hop.username, privateKey: key)
            }
            throw IOSSessionError.unsupportedKey

        case .privateKeyFile:
            throw IOSSessionError.unsupportedAuth(String(localized: "私钥文件"))

        case .agent:
            throw IOSSessionError.unsupportedAuth("ssh-agent")
        }
    }
}
