import Foundation
import SwiftData

enum Persistence {
    /// BERTH_TRANSIENT_STORE=1 时使用内存库(自动化验收/测试),不污染用户数据
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Host.self, HostGroup.self, SSHKeyRecord.self, PortForward.self, Snippet.self])
        let transient = ProcessInfo.processInfo.environment["BERTH_TRANSIENT_STORE"] == "1"
        let configuration: ModelConfiguration
        if transient {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(schema: schema, url: storeURL())
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
}
