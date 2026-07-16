import AppKit
import Citadel
import Crypto
import Foundation
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

        var errorDescription: String? {
            "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。"
        }
    }

    let id = UUID()
    let spec: HostSpec
    let terminalView: TerminalView

    private(set) var state: State = .idle

    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var stdinWriter: AsyncStream<StdinEvent>.Continuation?
    @ObservationIgnored private var userInitiatedDisconnect = false
    /// 自动化验收用:绕过 Keychain 的临时密码(不落任何持久化)
    @ObservationIgnored var transientPassword: String?

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    init(spec: HostSpec) {
        self.spec = spec
        let fontSize = CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(srgbRed: 0.922, green: 0.933, blue: 0.941, alpha: 1)
        terminalView.caretColor = .systemTeal
        terminalView.terminalDelegate = self
    }

    // MARK: - 生命周期

    /// 可重入:disconnected 后再次调用即手动重连
    func connect() {
        guard sessionTask == nil else { return }
        userInitiatedDisconnect = false
        state = .connecting(detail: "正在连接 \(spec.hostname):\(spec.port)…")

        sessionTask = Task {
            do {
                try await runSession()
                state = .disconnected(userInitiatedDisconnect ? .userInitiated : .remoteClosed)
            } catch is CancellationError {
                state = .disconnected(.userInitiated)
            } catch {
                state = .disconnected(userInitiatedDisconnect
                    ? .userInitiated
                    : .error(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port)))
            }
            stdinWriter?.finish()
            stdinWriter = nil
            let client = self.client
            self.client = nil
            sessionTask = nil
            Task.detached { try? await client?.close() }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        sessionTask?.cancel()
        let client = self.client
        Task.detached { try? await client?.close() }
    }

    /// 关闭标签页时调用:断开并放弃会话
    func shutdown() {
        disconnect()
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
    }

    func focusTerminal() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - 连接实现

    private func runSession() async throws {
        let method = try makeAuthenticationMethod()
        let client = try await SSHClient.connect(
            host: spec.hostname,
            port: spec.port,
            authenticationMethod: method,
            hostKeyValidator: .acceptAnything(), // TODO(M2): known_hosts 校验 + 指纹确认,当前不校验 host key
            reconnect: .never
        )
        self.client = client
        state = .connecting(detail: "认证成功,正在打开终端通道…")

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
                self.focusTerminal()
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

    private func makeAuthenticationMethod() throws -> SSHAuthenticationMethod {
        switch spec.authMethod {
        case .password:
            let password = try transientPassword
                ?? KeychainStore.read(account: KeychainStore.passwordAccount(for: spec.hostID))
                ?? ""
            return .passwordBased(username: spec.username, password: password)

        case .privateKeyFile:
            guard let path = spec.privateKeyPath, !path.isEmpty else { throw SessionError.unsupportedKey }
            let expanded = NSString(string: path).expandingTildeInPath
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let passphrase = try KeychainStore.read(account: KeychainStore.passphraseAccount(for: spec.hostID))
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: spec.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
                return .rsa(username: spec.username, privateKey: key)
            }
            throw SessionError.unsupportedKey
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
