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
    let proxy: ProxyConfig
    /// 跳板链(由外到内,已解析)。连接时:连 jump[0] → jump[1] → … → 目标本机。
    /// 空 = 直连。由 SessionManager 从 Host.jumpHostID 递归解析后填入。
    var jump: [HostSpec]

    init(
        hostID: UUID,
        label: String,
        hostname: String,
        port: Int,
        username: String,
        authMethod: AuthMethodKind,
        privateKeyPath: String?,
        keyID: UUID? = nil,
        proxy: ProxyConfig = ProxyConfig(),
        jump: [HostSpec] = []
    ) {
        self.hostID = hostID
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.keyID = keyID
        self.proxy = proxy
        self.jump = jump
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
        self.proxy = host.proxy
        self.jump = []
    }

    /// 递归解析 host.jumpHostID → 完整跳板链(由外到内)。防环。
    static func resolve(_ host: Host, in allHosts: [Host]) -> HostSpec {
        let byID = Dictionary(allHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [HostSpec] = []
        var seen: Set<UUID> = [host.id]
        var current = host.jumpHostID
        while let jumpID = current, !seen.contains(jumpID), let jumpHost = byID[jumpID] {
            seen.insert(jumpID)
            chain.insert(HostSpec(host: jumpHost), at: 0) // 外层在前
            current = jumpHost.jumpHostID
        }
        var spec = HostSpec(host: host)
        spec.jump = chain
        return spec
    }
}
