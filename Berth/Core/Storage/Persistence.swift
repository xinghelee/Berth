import Foundation
import SwiftData

enum Persistence {
    /// BERTH_TRANSIENT_STORE=1 时使用内存库(自动化验收/测试),不污染用户数据
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Host.self, HostGroup.self, SSHKeyRecord.self, PortForward.self, Snippet.self, Workspace.self, Trigger.self])
        let transient = ProcessInfo.processInfo.environment["BERTH_TRANSIENT_STORE"] == "1"
        let configuration: ModelConfiguration
        // cloudKitDatabase 显式 .none:app 已带 iCloud entitlement,SwiftData 默认会
        // 自动开 CloudKit 集成并要求所有属性 optional/有默认值(现有模型不满足)。
        // CloudKit 同步在专门的里程碑里完成模型适配后再开启。
        if transient {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, url: storeURL(), cloudKitDatabase: .none)
        }
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法创建数据库容器: \(error)")
        }
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Berth", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Berth.store")
    }

    /// 一次性迁移:清掉历史 bug 产生的完全重复托管主机(同地址+端口+用户名)。
    /// 保留优先级:Keychain 有密码 > 有转发/分组/备注 > sortOrder 靠前。
    static func dedupManualHosts(container: ModelContainer) {
        let flag = "migration.dedupHosts.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        let context = ModelContext(container)
        let hosts = (try? context.fetch(FetchDescriptor<Host>())) ?? []
        var buckets: [String: [Host]] = [:]
        for host in hosts where host.source != .sshConfig {
            buckets["\(host.hostname)|\(host.port)|\(host.username)", default: []].append(host)
        }
        var removed = 0
        for (_, dupes) in buckets where dupes.count > 1 {
            let keeper = dupes.first { ((try? KeychainStore.read(account: KeychainStore.passwordAccount(for: $0.id))) ?? nil) != nil }
                ?? dupes.first { !$0.portForwards.isEmpty || $0.group != nil || !$0.note.isEmpty }
                ?? dupes.min { $0.sortOrder < $1.sortOrder }!
            for host in dupes where host.id != keeper.id {
                KeychainStore.deleteSecrets(for: host.id)
                context.delete(host)
                removed += 1
            }
        }
        if removed > 0 { try? context.save() }
    }
}
