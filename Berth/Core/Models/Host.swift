import Foundation
import SwiftData

enum TagColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, green, blue, purple
    var id: String { rawValue }
}

/// M1 支持密码与私钥文件;M2 引入 SSHKey 实体后增加 privateKey(keyID),M3 增加 agent
enum AuthMethodKind: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKeyFile
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
    var group: HostGroup?
    var tagColorRaw: String
    var note: String
    var sortOrder: Int
    var sourceRaw: String
    var lastConnectedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethodKind = .password,
        privateKeyPath: String? = nil,
        group: HostGroup? = nil,
        tagColor: TagColor = .none,
        note: String = "",
        sortOrder: Int = 0,
        source: HostSource = .manual
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.privateKeyPath = privateKeyPath
        self.group = group
        self.tagColorRaw = tagColor.rawValue
        self.note = note
        self.sortOrder = sortOrder
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
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
