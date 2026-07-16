import AppKit
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import SwiftTerm

/// M0 技术验证:Citadel 连接 → 认证 → PTY → SwiftTerm 渲染。
/// 刻意保持直白的单类实现,M1 再拆分为 SSHSession/SessionManager 正式架构。
@MainActor
final class SpikeSession: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case disconnected
        case failed(String)
    }

    enum Auth {
        case password(String)
        case privateKey(path: String, passphrase: String?)
    }

    enum SpikeError: LocalizedError {
        case unsupportedKey

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { debugLog("phase: \(phase)") }
    }

    /// --autotest 时写入 <dumpPath>.log,便于无 UI 观测下排障
    var debugLogPath: String?

    private func debugLog(_ message: String) {
        guard let path = debugLogPath else { return }
        let line = "\(Date()) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    private var client: SSHClient?
    private var sessionTask: Task<Void, Never>?
    private var stdinWriter: AsyncStream<StdinEvent>.Continuation?

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    override init() {
        super.init()
        terminalView.terminalDelegate = self
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(srgbRed: 0.922, green: 0.933, blue: 0.941, alpha: 1)
        terminalView.caretColor = .systemTeal
    }

    // MARK: - 连接生命周期

    func connect(host: String, port: Int, username: String, auth: Auth) {
        guard sessionTask == nil else { return }
        phase = .connecting("正在连接 \(host):\(port)…")

        sessionTask = Task {
            do {
                try await runSession(host: host, port: port, username: username, auth: auth)
                phase = .disconnected
            } catch is CancellationError {
                phase = .disconnected
            } catch {
                phase = .failed(Self.friendlyMessage(for: error, host: host, port: port))
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
        sessionTask?.cancel()
        let client = self.client
        Task.detached { try? await client?.close() }
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
    }

    // MARK: - 自动化验收(--autotest <dumpPath>,仅调试用)
    //
    // 连接成功后依次验证:命令输出渲染 → 窗口缩放触发 WindowChangeRequest
    // (前后 stty size 应不同)→ vim 全屏 TUI(alt buffer)。
    // 结束时把 normal/alt 两个缓冲区文本写到 dumpPath.normal / dumpPath.alt。
    func runAutoTest(dumpPath: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            sendText("echo SIZE1=$(stty size | tr ' ' 'x')\n")

            try? await Task.sleep(for: .seconds(1.0))
            if let window = terminalView.window {
                var frame = window.frame
                frame.size.width -= 220
                frame.size.height -= 120
                window.setFrame(frame, display: true)
            }

            try? await Task.sleep(for: .seconds(1.5))
            sendText("echo SIZE2=$(stty size | tr ' ' 'x')\n")

            try? await Task.sleep(for: .seconds(1.0))
            sendText("vim /etc/passwd\n")

            try? await Task.sleep(for: .seconds(2.5))
            let terminal = terminalView.getTerminal()
            try? terminal.getBufferAsData(kind: .normal).write(to: URL(fileURLWithPath: dumpPath + ".normal"))
            try? terminal.getBufferAsData(kind: .alt).write(to: URL(fileURLWithPath: dumpPath + ".alt"))
        }
    }

    private func runSession(host: String, port: Int, username: String, auth: Auth) async throws {
        let method = try Self.authenticationMethod(username: username, auth: auth)
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: method,
            hostKeyValidator: .acceptAnything(), // 仅限 M0 spike;M2 接入 known_hosts 校验
            reconnect: .never
        )
        self.client = client
        phase = .connecting("认证成功,正在打开 PTY…")

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
                self.phase = .connected
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

    private func focusTerminal() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - 认证

    private static func authenticationMethod(username: String, auth: Auth) throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let password):
            return .passwordBased(username: username, password: password)

        case .privateKey(let path, let passphrase):
            let expanded = NSString(string: path).expandingTildeInPath
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }

            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
                return .rsa(username: username, privateKey: key)
            }
            throw SpikeError.unsupportedKey
        }
    }

    // MARK: - 错误信息人话化(spike 版,M2 完整实现)

    private static func friendlyMessage(for error: Error, host: String, port: Int) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("allAuthenticationOptionsFailed")
            || raw.localizedCaseInsensitiveContains("authentication") {
            return "服务器拒绝了认证:检查用户名、密码或密钥是否正确(公钥是否已加入 authorized_keys)。"
        }
        if raw.localizedCaseInsensitiveContains("refused") {
            return "连不上 \(host):\(port):连接被拒绝,检查端口号和 sshd 是否在运行。"
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.localizedCaseInsensitiveContains("timeout") {
            return "连不上 \(host):\(port):连接超时,检查地址、防火墙或网络。"
        }
        if error is SpikeError {
            return error.localizedDescription
        }
        return "连接失败:\(raw)"
    }
}

// MARK: - TerminalViewDelegate(AppKit 主线程回调)

extension SpikeSession: TerminalViewDelegate {

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
