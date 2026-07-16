import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// 验收专用:用指定 known_hosts 校验器跑一次真实连接,建立 PTY 即算成功。
/// 与 TerminalSession 共用底层组件(InteractiveHostKeyValidator),
/// 但不涉及 UI,便于 headless 断言 host key 决策路径。
struct ConnectionProbe {
    let store: KnownHostsStore
    let decision: @Sendable (HostKeyPrompt) -> Bool

    func run(spec: HostSpec, password: String) async -> Bool {
        let validator = InteractiveHostKeyValidator(
            hostname: spec.hostname,
            port: spec.port,
            store: store
        ) { prompt in
            decision(prompt)
        }
        do {
            let client = try await SSHClient.connect(
                host: spec.hostname,
                port: spec.port,
                authenticationMethod: .passwordBased(username: spec.username, password: password),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
            var opened = false
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm",
                terminalCharacterWidth: 80,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([:])
            )
            try await client.withPTY(request) { _, outbound in
                opened = true
                try await outbound.write(ByteBuffer(bytes: Array("exit\n".utf8)))
            }
            try? await client.close()
            return opened
        } catch {
            return false
        }
    }
}

/// 运行时随机公钥 blob(篡改 known_hosts 用)
enum NIOSSHPublicKeyFixtureRuntime {
    static func randomBlobBase64() throws -> String {
        let key = Curve25519.Signing.PrivateKey().publicKey
        var blob = Data()
        func appendString(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(data)
        }
        appendString(Data("ssh-ed25519".utf8))
        appendString(key.rawRepresentation)
        return blob.base64EncodedString()
    }
}
