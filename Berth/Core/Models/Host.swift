import Foundation
import SwiftData

enum TagColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, green, blue, purple
    var id: String { rawValue }
}

enum AuthMethodKind: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKeyFile
    /// 密钥库中的密钥(SSHKeyRecord,私钥在 Keychain)
    case storedKey
    /// 系统 ssh-agent(读 SSH_AUTH_SOCK)
    case agent
    var id: String { rawValue }
}

enum HostSource: String, Codable {
    case manual
    case sshConfig // M2:~/.ssh/config 只读镜像
}

@Model
final class Host {
    @Attribute(.unique) var id: UUID
    var label: String
    var hostname: String
    var port: Int
    var username: String
    var authMethodRaw: String
    /// authMethod == .privateKeyFile 时的私钥文件路径(支持 ~ 展开)
    var privateKeyPath: String?
    /// authMethod == .storedKey 时引用的 SSHKeyRecord.id
    var keyID: UUID?
    var group: HostGroup?
    var tagColorRaw: String
    var note: String
    var sortOrder: Int
    var sourceRaw: String
    var lastConnectedAt: Date?
    var createdAt: Date
    /// 跳板机:另一台 Host 的 id(等效 ProxyJump),支持链式
    var jumpHostID: UUID?
    /// 代理:拍平成基础字段存储(SwiftData 对嵌套枚举的复合 Codable 属性支持不稳,故不直接存 struct)
    var proxyKindRaw: String = ProxyKind.none.rawValue
    var proxyHost: String = ""
    var proxyPort: Int = 1080
    var proxyUsername: String = ""
    var proxyRequiresAuth: Bool = false
    /// 标记为生产环境:终端顶部红色警戒条 + 粘贴/危险命令强制确认
    var isProduction: Bool = false
    /// 连接建立后自动执行的命令(每行一条,自动补回车)
    var startupCommands: String = ""
    @Relationship(deleteRule: .cascade, inverse: \PortForward.host) var portForwards: [PortForward] = []

    init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethodKind = .password,
        privateKeyPath: String? = nil,
        keyID: UUID? = nil,
        group: HostGroup? = nil,
        tagColor: TagColor = .none,
        note: String = "",
        sortOrder: Int = 0,
        source: HostSource = .manual,
        jumpHostID: UUID? = nil,
        proxy: ProxyConfig = ProxyConfig(),
        isProduction: Bool = false,
        startupCommands: String = ""
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.privateKeyPath = privateKeyPath
        self.keyID = keyID
        self.group = group
        self.tagColorRaw = tagColor.rawValue
        self.note = note
        self.sortOrder = sortOrder
        self.sourceRaw = source.rawValue
        self.jumpHostID = jumpHostID
        self.proxyKindRaw = proxy.kind.rawValue
        self.proxyHost = proxy.host
        self.proxyPort = proxy.port
        self.proxyUsername = proxy.username
        self.proxyRequiresAuth = proxy.requiresAuth
        self.isProduction = isProduction
        self.startupCommands = startupCommands
        self.createdAt = Date()
    }

    /// 代理值的读写(桥接拍平字段 ↔ ProxyConfig)
    var proxy: ProxyConfig {
        get {
            ProxyConfig(
                kind: ProxyKind(rawValue: proxyKindRaw) ?? .none,
                host: proxyHost,
                port: proxyPort,
                username: proxyUsername,
                requiresAuth: proxyRequiresAuth
            )
        }
        set {
            proxyKindRaw = newValue.kind.rawValue
            proxyHost = newValue.host
            proxyPort = newValue.port
            proxyUsername = newValue.username
            proxyRequiresAuth = newValue.requiresAuth
        }
    }

    var authMethod: AuthMethodKind {
        get { AuthMethodKind(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    var tagColor: TagColor {
        get { TagColor(rawValue: tagColorRaw) ?? .none }
        set { tagColorRaw = newValue.rawValue }
    }

    var source: HostSource {
        get { HostSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// 显示用 user@host[:port]
    var address: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

@Model
final class HostGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    @Relationship(deleteRule: .nullify, inverse: \Host.group) var hosts: [Host] = []

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}
