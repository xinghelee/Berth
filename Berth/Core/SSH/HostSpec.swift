import Foundation

/// 端口转发的值快照(Sendable,供连接层使用)
struct PortForwardSpec: Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: PortForwardKind
    let bindHost: String
    let bindPort: Int
    let targetHost: String
    let targetPort: Int

    init(_ forward: PortForward) {
        self.id = forward.id
        self.kind = forward.kind
        self.bindHost = forward.bindHost
        self.bindPort = forward.bindPort
        self.targetHost = forward.targetHost
        self.targetPort = forward.targetPort
    }

    init(id: UUID = UUID(), kind: PortForwardKind, bindHost: String, bindPort: Int, targetHost: String, targetPort: Int) {
        self.id = id
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    var summary: String {
        switch kind {
        case .local: return String(localized: "本地 \(bindHost):\(String(bindPort)) → \(targetHost):\(String(targetPort))")
        case .remote: return String(localized: "远程 \(bindHost):\(String(bindPort)) → \(targetHost):\(String(targetPort))")
        case .dynamic: return "SOCKS5 \(bindHost):\(bindPort)"
        }
    }
}

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
    /// 连接后自动建立的端口转发(仅启用的)
    let forwards: [PortForwardSpec]
    /// 生产环境标记:红色警戒条 + 强制粘贴/危险命令确认
    var isProduction: Bool = false
    /// 标签色(none 时不显示配色条),用于 pane 顶部环境色条
    var tagColorRaw: String = TagColor.none.rawValue
    /// 连接建立后自动执行的命令(每行一条)
    var startupCommands: String = ""

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
        jump: [HostSpec] = [],
        forwards: [PortForwardSpec] = [],
        isProduction: Bool = false,
        tagColorRaw: String = TagColor.none.rawValue,
        startupCommands: String = ""
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
        self.forwards = forwards
        self.isProduction = isProduction
        self.tagColorRaw = tagColorRaw
        self.startupCommands = startupCommands
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
        self.isProduction = host.isProduction
        self.tagColorRaw = host.tagColorRaw
        self.startupCommands = host.startupCommands
        self.jump = []
        self.forwards = host.portForwards
            .filter(\.enabled)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(PortForwardSpec.init)
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
        var spec = HostSpec(host: host) // forwards 已在 init(host:) 里解析
        spec.jump = chain
        return spec
    }
}
