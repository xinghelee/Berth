import Foundation

/// Host 的连接参数值快照:会话层不直接持有 SwiftData 对象,
/// 避免跨线程访问模型上下文;凭据在连接时按 hostID 从 Keychain 解析。
struct HostSpec: Equatable, Sendable {
    let hostID: UUID
    let label: String
    let hostname: String
    let port: Int
    let username: String
    let authMethod: AuthMethodKind
    let privateKeyPath: String?
    let keyID: UUID?

    init(
        hostID: UUID,
        label: String,
        hostname: String,
        port: Int,
        username: String,
        authMethod: AuthMethodKind,
        privateKeyPath: String?,
        keyID: UUID? = nil
    ) {
        self.hostID = hostID
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.keyID = keyID
    }

    init(host: Host) {
        self.hostID = host.id
        self.label = host.label
        self.hostname = host.hostname
        self.port = host.port
        self.username = host.username
        self.authMethod = host.authMethod
        self.privateKeyPath = host.privateKeyPath
        self.keyID = host.keyID
    }
}
