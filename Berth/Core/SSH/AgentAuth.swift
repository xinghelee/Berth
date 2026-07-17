import Foundation
import NIOCore
import NIOSSH

/// ssh-agent 认证:把 agent 里的密钥包装成 NIOSSH 自定义密钥,
/// signature(for:) 同步向 agent socket 请求签名。支持 ed25519 与 RSA(rsa-sha2-512)。
///
/// nio-ssh 的 writeSSHHostKey 对自定义公钥写 `string publicKeyPrefix` + `key.write(to:)`,
/// 故 write 只需原样写出 blob 里 keytype 之后的部分(keyBody)。签名同理。

// MARK: - 公钥

private protocol AgentBackedPublicKey: NIOSSHPublicKeyProtocol {}

extension AgentBackedPublicKey {
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw AgentAuthError.unsupported
    }
}

final class AgentEd25519PublicKey: AgentBackedPublicKey, @unchecked Sendable {
    static let publicKeyPrefix = "ssh-ed25519"
    let rawRepresentation: Data
    private let keyBody: Data
    init(keyBody: Data) { self.keyBody = keyBody; self.rawRepresentation = keyBody }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(keyBody) }
}

final class AgentRSAPublicKey: AgentBackedPublicKey, @unchecked Sendable {
    static let publicKeyPrefix = "ssh-rsa"
    // RSA 密钥 blob 类型是 ssh-rsa,但 OpenSSH 8.8+ 要求签名算法名为 rsa-sha2-512
    static let userAuthPrefix = "rsa-sha2-512"
    let rawRepresentation: Data
    private let keyBody: Data
    init(keyBody: Data) { self.keyBody = keyBody; self.rawRepresentation = keyBody }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(keyBody) }
}

// MARK: - 签名

private protocol AgentBackedSignature: NIOSSHSignatureProtocol {}

extension AgentBackedSignature {
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw AgentAuthError.unsupported }
}

/// 写出 `string sigblob`(agent 返回的裸签名),前缀由 nio-ssh 用 signaturePrefix 写。
private func writeSSHString(_ blob: Data, to buffer: inout ByteBuffer) -> Int {
    var written = buffer.writeInteger(UInt32(blob.count))
    written += buffer.writeBytes(blob)
    return written
}

final class AgentEd25519Signature: AgentBackedSignature, @unchecked Sendable {
    static let signaturePrefix = "ssh-ed25519"
    let rawRepresentation: Data
    init(sigblob: Data) { self.rawRepresentation = sigblob }
    func write(to buffer: inout ByteBuffer) -> Int { writeSSHString(rawRepresentation, to: &buffer) }
}

final class AgentRSASignature: AgentBackedSignature, @unchecked Sendable {
    static let signaturePrefix = "rsa-sha2-512"
    let rawRepresentation: Data
    init(sigblob: Data) { self.rawRepresentation = sigblob }
    func write(to buffer: inout ByteBuffer) -> Int { writeSSHString(rawRepresentation, to: &buffer) }
}

// MARK: - 私钥(向 agent 请求签名)

// SSH_AGENT_RSA_SHA2_512
private let rsaSHA2512Flag: UInt32 = 4

final class AgentEd25519PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static let keyPrefix = "ssh-ed25519"
    private let agent: SSHAgentClient
    private let keyBlob: Data
    private let _publicKey: AgentEd25519PublicKey

    init(agent: SSHAgentClient, keyBlob: Data) {
        self.agent = agent
        self.keyBlob = keyBlob
        var reader = SSHWireReader(keyBlob)
        _ = reader.readString() // keytype
        self._publicKey = AgentEd25519PublicKey(keyBody: reader.remaining())
    }

    var publicKey: NIOSSHPublicKeyProtocol { _publicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let response = try agent.sign(keyBlob: keyBlob, data: Data(data), flags: 0)
        var reader = SSHWireReader(response)
        _ = reader.readString() // sigformat
        guard let sigblob = reader.readData() else { throw AgentAuthError.signatureFailed }
        return AgentEd25519Signature(sigblob: sigblob)
    }
}

final class AgentRSAPrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static let keyPrefix = "ssh-rsa"
    private let agent: SSHAgentClient
    private let keyBlob: Data
    private let _publicKey: AgentRSAPublicKey

    init(agent: SSHAgentClient, keyBlob: Data) {
        self.agent = agent
        self.keyBlob = keyBlob
        var reader = SSHWireReader(keyBlob)
        _ = reader.readString()
        self._publicKey = AgentRSAPublicKey(keyBody: reader.remaining())
    }

    var publicKey: NIOSSHPublicKeyProtocol { _publicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let response = try agent.sign(keyBlob: keyBlob, data: Data(data), flags: rsaSHA2512Flag)
        var reader = SSHWireReader(response)
        _ = reader.readString() // sigformat("rsa-sha2-512")
        guard let sigblob = reader.readData() else { throw AgentAuthError.signatureFailed }
        return AgentRSASignature(sigblob: sigblob)
    }
}

// MARK: - 认证 delegate

enum AgentAuthError: LocalizedError {
    case noAgent
    case noIdentities
    case unsupported
    case signatureFailed

    var errorDescription: String? {
        switch self {
        case .noAgent: return String(localized: "找不到 ssh-agent(SSH_AUTH_SOCK 未设置)。")
        case .noIdentities: return String(localized: "ssh-agent 里没有可用的密钥(试试 ssh-add)。")
        case .unsupported: return String(localized: "该密钥类型暂不支持通过 agent 认证(目前支持 ed25519 / RSA)。")
        case .signatureFailed: return String(localized: "ssh-agent 签名失败。")
        }
    }
}

/// 逐个尝试 agent 里(受支持类型)的密钥。
final class AgentAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let agent: SSHAgentClient
    private let identities: [SSHAgentClient.Identity]
    private var index = 0

    private static let supportedTypes: Set<String> = ["ssh-ed25519", "ssh-rsa"]

    init(username: String, agent: SSHAgentClient, identities: [SSHAgentClient.Identity]) {
        self.username = username
        self.agent = agent
        self.identities = identities.filter { Self.supportedTypes.contains($0.keyType) }
    }

    var hasUsableKeys: Bool { !identities.isEmpty }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), index < identities.count else {
            nextChallengePromise.succeed(nil)
            return
        }
        let identity = identities[index]
        index += 1
        do {
            let key = try makeKey(for: identity)
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: key))
            )
            nextChallengePromise.succeed(offer)
        } catch {
            nextChallengePromise.succeed(nil)
        }
    }

    private func makeKey(for identity: SSHAgentClient.Identity) throws -> NIOSSHPrivateKey {
        switch identity.keyType {
        case "ssh-ed25519":
            return NIOSSHPrivateKey(custom: AgentEd25519PrivateKey(agent: agent, keyBlob: identity.keyBlob))
        case "ssh-rsa":
            return NIOSSHPrivateKey(custom: AgentRSAPrivateKey(agent: agent, keyBlob: identity.keyBlob))
        default:
            throw AgentAuthError.unsupported
        }
    }
}
