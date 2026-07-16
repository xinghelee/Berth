import Foundation
import SwiftData

/// JSON 备份导入导出。**只备份结构**(主机/分组/转发/代理配置),
/// 不含任何明文密码、passphrase、私钥 —— 这些在 Keychain,导入后需重新填写。
enum BackupService {

    struct Backup: Codable {
        var version = 1
        var exportedAt: Date
        var groups: [GroupDTO]
        var hosts: [HostDTO]
    }

    struct GroupDTO: Codable {
        var id: UUID
        var name: String
        var sortOrder: Int
    }

    struct HostDTO: Codable {
        var id: UUID
        var label: String
        var hostname: String
        var port: Int
        var username: String
        var authMethod: String
        var privateKeyPath: String?
        var keyID: UUID?
        var groupID: UUID?
        var jumpHostID: UUID?
        var tagColor: String
        var note: String
        var sortOrder: Int
        var proxyKind: String
        var proxyHost: String
        var proxyPort: Int
        var proxyUsername: String
        var forwards: [ForwardDTO]
    }

    struct ForwardDTO: Codable {
        var kind: String
        var bindHost: String
        var bindPort: Int
        var targetHost: String
        var targetPort: Int
        var enabled: Bool
        var sortOrder: Int
    }

    // MARK: - 导出

    static func export(context: ModelContext) throws -> Data {
        let groups = (try? context.fetch(FetchDescriptor<HostGroup>())) ?? []
        // 只导出手动管理的主机(ssh_config 镜像不备份,它由 config 文件本身托管)
        let hosts = ((try? context.fetch(FetchDescriptor<Host>())) ?? [])
            .filter { $0.source == .manual }

        let backup = Backup(
            exportedAt: Date(),
            groups: groups.map { GroupDTO(id: $0.id, name: $0.name, sortOrder: $0.sortOrder) },
            hosts: hosts.map { host in
                HostDTO(
                    id: host.id,
                    label: host.label,
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    authMethod: host.authMethodRaw,
                    privateKeyPath: host.privateKeyPath,
                    keyID: host.keyID,
                    groupID: host.group?.id,
                    jumpHostID: host.jumpHostID,
                    tagColor: host.tagColorRaw,
                    note: host.note,
                    sortOrder: host.sortOrder,
                    proxyKind: host.proxyKindRaw,
                    proxyHost: host.proxyHost,
                    proxyPort: host.proxyPort,
                    proxyUsername: host.proxyUsername,
                    forwards: host.portForwards
                        .sorted { $0.sortOrder < $1.sortOrder }
                        .map { forward in
                            ForwardDTO(
                                kind: forward.kindRaw, bindHost: forward.bindHost, bindPort: forward.bindPort,
                                targetHost: forward.targetHost, targetPort: forward.targetPort,
                                enabled: forward.enabled, sortOrder: forward.sortOrder
                            )
                        }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    // MARK: - 导入

    /// 导入:已存在同 id 的主机/分组跳过(不覆盖),返回新增数量。
    @discardableResult
    static func `import`(_ data: Data, context: ModelContext) throws -> (hosts: Int, groups: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)

        let existingGroupIDs = Set(((try? context.fetch(FetchDescriptor<HostGroup>())) ?? []).map(\.id))
        let existingHostIDs = Set(((try? context.fetch(FetchDescriptor<Host>())) ?? []).map(\.id))

        var groupsByID: [UUID: HostGroup] = [:]
        var addedGroups = 0
        for dto in backup.groups where !existingGroupIDs.contains(dto.id) {
            let group = HostGroup(id: dto.id, name: dto.name, sortOrder: dto.sortOrder)
            context.insert(group)
            groupsByID[dto.id] = group
            addedGroups += 1
        }

        var addedHosts = 0
        for dto in backup.hosts where !existingHostIDs.contains(dto.id) {
            let host = Host(
                id: dto.id,
                label: dto.label,
                hostname: dto.hostname,
                port: dto.port,
                username: dto.username,
                authMethod: AuthMethodKind(rawValue: dto.authMethod) ?? .password,
                privateKeyPath: dto.privateKeyPath,
                keyID: dto.keyID,
                group: dto.groupID.flatMap { groupsByID[$0] },
                tagColor: TagColor(rawValue: dto.tagColor) ?? .none,
                note: dto.note,
                sortOrder: dto.sortOrder,
                jumpHostID: dto.jumpHostID,
                proxy: ProxyConfig(
                    kind: ProxyKind(rawValue: dto.proxyKind) ?? .none,
                    host: dto.proxyHost,
                    port: dto.proxyPort,
                    username: dto.proxyUsername,
                    requiresAuth: !dto.proxyUsername.isEmpty
                )
            )
            context.insert(host)
            for forwardDTO in dto.forwards {
                let forward = PortForward(
                    kind: PortForwardKind(rawValue: forwardDTO.kind) ?? .local,
                    bindHost: forwardDTO.bindHost, bindPort: forwardDTO.bindPort,
                    targetHost: forwardDTO.targetHost, targetPort: forwardDTO.targetPort,
                    enabled: forwardDTO.enabled, sortOrder: forwardDTO.sortOrder
                )
                forward.host = host
                context.insert(forward)
            }
            addedHosts += 1
        }

        try context.save()
        return (addedHosts, addedGroups)
    }
}
