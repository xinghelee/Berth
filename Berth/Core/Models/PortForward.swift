import Foundation
import SwiftData

enum PortForwardKind: String, Codable, CaseIterable, Identifiable {
    case local    // -L 本地端口 → 远端
    case remote   // -R 远端端口 → 本地
    case dynamic  // -D 本地 SOCKS5
    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "本地 (-L)"
        case .remote: return "远程 (-R)"
        case .dynamic: return "动态 SOCKS5 (-D)"
        }
    }
}

/// 一条端口转发规则。dynamic 只用 bindHost/bindPort(本地 SOCKS5 监听),
/// target 字段忽略。
@Model
final class PortForward {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var bindHost: String     // 本地监听地址(local/dynamic)或远端监听地址(remote)
    var bindPort: Int
    var targetHost: String   // local/remote 的目标主机
    var targetPort: Int
    var enabled: Bool
    var host: Host?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        kind: PortForwardKind = .local,
        bindHost: String = "127.0.0.1",
        bindPort: Int = 0,
        targetHost: String = "",
        targetPort: Int = 0,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    var kind: PortForwardKind {
        get { PortForwardKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    /// 人类可读摘要,如 "127.0.0.1:8080 → db:5432"
    var summary: String {
        switch kind {
        case .local:
            return "\(bindHost):\(bindPort) → \(targetHost):\(targetPort)"
        case .remote:
            return "远端 \(bindHost):\(bindPort) → \(targetHost):\(targetPort)"
        case .dynamic:
            return "SOCKS5 \(bindHost):\(bindPort)"
        }
    }
}
