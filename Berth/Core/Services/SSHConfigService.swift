import CryptoKit
import Foundation
import SwiftData

/// ~/.ssh/config 导入与文件监听。
/// 镜像主机是**内存态**只读视图(source == .sshConfig,不插入任何 ModelContext):
/// 本机 config 是设备私有内容,入库会被 CloudKit 同步扩散到其它设备并互相打架。
/// 每次同步整体对齐(新增/更新/删除),用户编辑需先「转为托管主机」。
/// id 由 alias 决定性派生,跨启动/跨设备稳定,会话恢复与模板按 id 仍可命中。
@MainActor
@Observable
final class SSHConfigService {
    static let shared = SSHConfigService()

    /// config 的内存镜像,按 config 文件内出现顺序排列
    private(set) var mirrorHosts: [Host] = []

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    var configPath: String { NSString(string: "~/.ssh/config").expandingTildeInPath }
    private var sshDirectory: String { NSString(string: "~/.ssh").expandingTildeInPath }

    func start(container: ModelContainer) {
        guard !started else { return }
        // 临时库实例(自动化验收/演示场景)保持密闭,不镜像真实 ~/.ssh/config
        if ProcessInfo.processInfo.environment["BERTH_TRANSIENT_STORE"] == "1" { return }
        started = true
        purgeLegacyMirrorRows(container: container)
        sync()
        startWatching()
    }

    /// 历史版本把镜像主机存进了库;内存化后清掉残留行(幂等,防止随 CloudKit 扩散)
    private func purgeLegacyMirrorRows(container: ModelContainer) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.sourceRaw == "sshConfig" })
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for host in stale { context.delete(host) }
        try? context.save()
    }

    /// alias → 稳定 UUID(SHA-256 前 16 字节),跨启动/设备一致
    private static func mirrorID(alias: String) -> UUID {
        let digest = SHA256.hash(data: Data("berth.sshconfig.\(alias)".utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// 从 ~/.ssh/config 移除某个别名对应的 Host 块(删除前自动备份),随后重新同步。
    /// 若一个 Host 行含多个别名,只移除该别名;它是块内唯一别名时移除整块。
    @discardableResult
    func removeHostFromConfig(alias: String) -> Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        backupConfig()

        var output: [String] = []
        var skippingBlock = false
        var changed = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower == "host" || lower.hasPrefix("host ") || lower.hasPrefix("host\t") {
                // 新的 Host 行:结束上一个块的跳过状态
                let patterns = trimmed
                    .dropFirst(4)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                if patterns.contains(alias) {
                    changed = true
                    if patterns.count > 1 {
                        // 多别名:保留其它别名,去掉本别名
                        let kept = patterns.filter { $0 != alias }
                        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                        output.append("\(indent)Host \(kept.joined(separator: " "))")
                        skippingBlock = false
                    } else {
                        skippingBlock = true // 整块丢弃到下一个 Host/Match
                    }
                    continue
                } else {
                    skippingBlock = false
                }
            } else if lower == "match" || lower.hasPrefix("match ") {
                skippingBlock = false
            }

            if !skippingBlock {
                output.append(line)
            }
        }

        guard changed else { return false }
        try? output.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
        sync()
        return true
    }

    private func backupConfig() {
        let backup = configPath + ".berth-backup"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.copyItem(atPath: configPath, toPath: backup)
    }

    /// 解析 config 并与库中 sshConfig 镜像对齐
    /// Git 托管服务的 ssh 别名(git@github.com 等)没有 shell,不作为终端主机导入
    private static let gitHostingDomains: Set<String> = [
        "github.com", "ssh.github.com", "gist.github.com",
        "gitlab.com", "altssh.gitlab.com",
        "bitbucket.org", "altssh.bitbucket.org",
        "gitee.com", "codeberg.org", "git.sr.ht",
        "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
    ]

    func sync() {
        let parsed = SSHConfigParser.parseFile(at: configPath)
            .filter { !Self.gitHostingDomains.contains($0.hostname.lowercased()) }

        // 复用旧实例保持 lastConnectedAt/osName 等运行期状态;config 已删的自然淘汰
        var previous = Dictionary(mirrorHosts.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        mirrorHosts = parsed.map { entry in
            let host = previous.removeValue(forKey: entry.alias)
                ?? Host(id: Self.mirrorID(alias: entry.alias),
                        label: entry.alias, hostname: entry.hostname, username: "", source: .sshConfig)
            host.hostname = entry.hostname
            host.port = entry.port ?? 22
            host.username = entry.user ?? NSUserName()
            if entry.prefersPasswordAuth {
                // config 明确禁用公钥(PubkeyAuthentication no / PreferredAuthentications
                // 不含 publickey):按密码认证导入,密码首次连接前需在 Keychain 里补
                host.authMethod = .password
                host.privateKeyPath = nil
            } else if let identityFile = entry.identityFile {
                host.authMethod = .privateKeyFile
                host.privateKeyPath = identityFile
            } else {
                host.authMethod = .privateKeyFile
                host.privateKeyPath = defaultIdentityFile()
            }
            host.note = entry.proxyJump.map { String(localized: "ProxyJump \($0)(跳板机连接将在后续版本支持)") } ?? ""
            return host
        }
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
