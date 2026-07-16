import Foundation
import SwiftData

/// ~/.ssh/config 导入与文件监听。
/// 导入的主机以 source == .sshConfig 存库,是只读镜像:每次同步整体对齐
/// (新增/更新/删除),用户编辑需先「转为托管主机」。
@MainActor
final class SSHConfigService {
    static let shared = SSHConfigService()

    private var container: ModelContainer?
    private var watcher: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var started = false

    var configPath: String { NSString(string: "~/.ssh/config").expandingTildeInPath }
    private var sshDirectory: String { NSString(string: "~/.ssh").expandingTildeInPath }

    func start(container: ModelContainer) {
        guard !started else { return }
        started = true
        self.container = container
        sync()
        startWatching()
    }

    /// 解析 config 并与库中 sshConfig 镜像对齐
    func sync() {
        guard let container else { return }
        let parsed = SSHConfigParser.parseFile(at: configPath)
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<Host>(
            predicate: #Predicate { $0.sourceRaw == "sshConfig" }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        var existingByAlias = Dictionary(existing.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in parsed {
            let host = existingByAlias.removeValue(forKey: entry.alias)
                ?? {
                    let created = Host(label: entry.alias, hostname: entry.hostname, username: "", source: .sshConfig)
                    context.insert(created)
                    return created
                }()
            host.hostname = entry.hostname
            host.port = entry.port ?? 22
            host.username = entry.user ?? NSUserName()
            if let identityFile = entry.identityFile {
                host.authMethod = .privateKeyFile
                host.privateKeyPath = identityFile
            } else {
                host.authMethod = .privateKeyFile
                host.privateKeyPath = defaultIdentityFile()
            }
            host.note = entry.proxyJump.map { "ProxyJump \($0)(跳板机连接将在后续版本支持)" } ?? ""
        }

        // config 中已移除的镜像主机一并删除
        for (_, stale) in existingByAlias {
            context.delete(stale)
        }
        try? context.save()
    }

    /// config 未指定 IdentityFile 时,按 ssh 默认顺序找一把存在的钥匙
    private func defaultIdentityFile() -> String? {
        let candidates = ["id_ed25519", "id_ecdsa", "id_rsa"]
        for name in candidates {
            let path = sshDirectory + "/" + name
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// 监听 ~/.ssh 目录(编辑器多为原子替换写入,监听目录比监听文件本身可靠)
    private func startWatching() {
        let fd = open(sshDirectory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleSync()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.sync()
        }
    }
}
