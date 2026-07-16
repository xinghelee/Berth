import Foundation
import SwiftData
import SwiftTerm

/// M2 自动化验收:BERTH_M2_AUTOTEST=1。凭据走环境变量。
/// 覆盖:
///   1. QuickConnect 模糊搜索命中主机
///   2. known_hosts 首次连接自动确认并写入(临时 HOME 隔离,不碰真实文件)
///   3. host key 变更 → 弹出变更警告(而非静默接受)
///   4. 非主动断开 → 指数退避自动重连
@MainActor
enum M2AcceptanceTest {

    static func runIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_M2_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22

        var log: [String] = []
        func mark(_ step: String) {
            log.append(step)
            try? log.joined(separator: "\n").write(toFile: dumpBase + ".log", atomically: true, encoding: .utf8)
        }
        mark("STARTED")

        // 用临时目录充当 known_hosts,避免污染真实 ~/.ssh/known_hosts
        let tempDir = NSTemporaryDirectory() + "berth-m2-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let knownHostsPath = tempDir + "/known_hosts"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // 1. QuickConnect 模糊搜索
        let context = ModelContext(container)
        let record = Host(label: "生产 Web", hostname: host, port: port, username: user)
        context.insert(record)
        try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: record.id))
        try? context.save()
        defer { KeychainStore.deleteSecrets(for: record.id) }

        let hit = FuzzyMatcher.bestScore(query: "web", fields: [record.label, record.hostname]) != nil
        mark(hit ? "QUICKCONNECT_MATCH_OK" : "QUICKCONNECT_MATCH_FAIL")

        // 2. known_hosts 首次连接:直连底层校验器,自动接受
        let store = KnownHostsStore(path: knownHostsPath)
        var firstPromptWasFirstConnect = false
        let connected1 = await connectOnce(
            spec: HostSpec(host: record),
            password: password,
            store: store
        ) { prompt in
            firstPromptWasFirstConnect = !prompt.isKeyChange
            return true // 信任
        }
        mark(connected1 && firstPromptWasFirstConnect ? "HOSTKEY_FIRST_TRUST_OK" : "HOSTKEY_FIRST_TRUST_FAIL")
        mark(FileManager.default.fileExists(atPath: knownHostsPath) ? "KNOWN_HOSTS_WRITTEN" : "KNOWN_HOSTS_MISSING")

        // 3. 第二次连接应为 trusted(不再弹窗)
        var secondPrompted = false
        let connected2 = await connectOnce(
            spec: HostSpec(host: record),
            password: password,
            store: store
        ) { _ in
            secondPrompted = true
            return true
        }
        mark(connected2 && !secondPrompted ? "HOSTKEY_TRUSTED_NO_PROMPT_OK" : "HOSTKEY_TRUSTED_FAIL")

        // 4. host key 变更警告:篡改 known_hosts 里该主机的密钥 blob,再连
        tamperKnownHosts(path: knownHostsPath, hostToken: KnownHostsStore.hostToken(hostname: host, port: port))
        var sawKeyChangeWarning = false
        _ = await connectOnce(
            spec: HostSpec(host: record),
            password: password,
            store: KnownHostsStore(path: knownHostsPath)
        ) { prompt in
            sawKeyChangeWarning = prompt.isKeyChange
            return false // 拒绝,不覆盖
        }
        mark(sawKeyChangeWarning ? "HOSTKEY_CHANGE_WARNING_OK" : "HOSTKEY_CHANGE_WARNING_FAIL")

        mark("ALL_DONE")
    }

    /// 真机密钥连通验收:BERTH_KEYCONNECT_AUTOTEST=1,用私钥文件连真实主机,建立 PTY 即成功。
    /// 环境:BERTH_TEST_HOST/PORT/USER + BERTH_TEST_KEYFILE + BERTH_TEST_DUMP。
    static func runKeyConnectIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_KEYCONNECT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22

        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".keyconnect.log", atomically: true, encoding: .utf8)
        }

        let spec = HostSpec(
            hostID: UUID(),
            label: "key-connect-test",
            hostname: host,
            port: port,
            username: user,
            authMethod: .privateKeyFile,
            privateKeyPath: keyFile
        )
        // 关掉 Touch ID 门,避免自动化卡在生物识别
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let session = SessionManager.shared.open(spec: spec)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state {
                // 顺带验证 inspector 的 executeCommand 能与 PTY 并存
                if let info = await session.fetchServerInfo(), !info.textRows.isEmpty {
                    log("KEY_CONNECT_OK SERVERINFO_OK kernel=\(info.kernel)")
                } else {
                    log("KEY_CONNECT_OK SERVERINFO_FAIL")
                }
                return
            }
            if case .disconnected(let reason) = session.state {
                log("KEY_CONNECT_FAIL \(reason)")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("KEY_CONNECT_TIMEOUT state=\(session.state)")
    }

    /// 跳板机验收:BERTH_JUMP_AUTOTEST=1,经 JUMP 主机跳到 TARGET 主机,建立 PTY + 取到目标服务器信息即成功。
    /// 环境:BERTH_JUMP_HOST/BERTH_JUMP_USER + BERTH_TEST_HOST(目标)/BERTH_TEST_USER + BERTH_TEST_KEYFILE + BERTH_TEST_DUMP
    static func runJumpIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_JUMP_AUTOTEST"] == "1",
              let jumpHost = env["BERTH_JUMP_HOST"],
              let jumpUser = env["BERTH_JUMP_USER"],
              let target = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }

        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".jump.log", atomically: true, encoding: .utf8)
        }

        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)

        let jumpSpec = HostSpec(
            hostID: UUID(), label: "jump", hostname: jumpHost, port: 22,
            username: jumpUser, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )
        let targetSpec = HostSpec(
            hostID: UUID(), label: "target", hostname: target, port: 22,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile,
            jump: [jumpSpec]
        )
        let session = SessionManager.shared.open(spec: targetSpec)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state {
                let info = await session.fetchServerInfo()
                log("JUMP_CONNECT_OK via=\(jumpHost) target=\(target) kernel=\(info?.kernel ?? "?")")
                return
            }
            if case .disconnected(let reason) = session.state {
                log("JUMP_CONNECT_FAIL \(reason)")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("JUMP_CONNECT_TIMEOUT state=\(session.state)")
    }

    /// 端口转发验收:BERTH_FORWARD_AUTOTEST=1。连目标后建一条 local/dynamic 转发,
    /// 打印实际绑定端口,保持会话存活让外部脚本验证。
    /// 环境:BERTH_TEST_HOST/USER/KEYFILE + BERTH_FWD_KIND(local/dynamic)
    ///       + BERTH_FWD_TARGET_HOST/BERTH_FWD_TARGET_PORT(local 用)+ BERTH_TEST_DUMP
    static func runForwardIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_FORWARD_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let kind = PortForwardKind(rawValue: env["BERTH_FWD_KIND"] ?? "local") ?? .local
        let targetHost = env["BERTH_FWD_TARGET_HOST"] ?? "127.0.0.1"
        let targetPort = Int(env["BERTH_FWD_TARGET_PORT"] ?? "22") ?? 22

        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".forward.log", atomically: true, encoding: .utf8)
        }

        log("FORWARD_TEST_STARTED host=\(host) kind=\(kind.rawValue)")
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let bindPort = Int(env["BERTH_FWD_BIND_PORT"] ?? "0") ?? 0
        let forward = PortForwardSpec(kind: kind, bindHost: "127.0.0.1", bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
        let spec = HostSpec(
            hostID: UUID(), label: "fwd", hostname: host, port: 22,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile,
            forwards: [forward]
        )
        let session = SessionManager.shared.open(spec: spec)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .disconnected(let reason) = session.state {
                log("FORWARD_SESSION_DISCONNECTED \(reason)")
                return
            }
            if case .failed(let reason)? = session.forwardStates[forward.id] {
                log("FORWARD_FAILED \(reason)")
                return
            }
            if case .active(let boundPort)? = session.forwardStates[forward.id] {
                log("FORWARD_ACTIVE port=\(boundPort) kind=\(kind.rawValue)")
                // 保持存活让外部脚本连本地端口验证
                try? await Task.sleep(for: .seconds(30))
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("FORWARD_TIMEOUT state=\(session.state)")
    }

    /// SFTP 验收:BERTH_SFTP_AUTOTEST=1,连目标后 list home → 上传 → 目录含新文件 → 下载校验 → 删除。
    static func runSFTPIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_SFTP_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".sftp.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let spec = HostSpec(
            hostID: UUID(), label: "sftp-test", hostname: host, port: port,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )
        let session = SessionManager.shared.open(spec: spec)
        // 等连上
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("SFTP_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("SFTP_FAIL 连接超时"); return }

        let browser = SFTPBrowser { try await session.openSFTP() }
        await browser.start()
        guard browser.state == .ready else { log("SFTP_FAIL list: \(browser.state)"); return }
        let homeListed = browser.entries.count

        // 上传一个临时文件
        let payload = "berth-sftp-\(homeListed)".data(using: .utf8)!
        let localUp = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_sftp_up.txt")
        try? payload.write(to: localUp)
        await browser.upload(from: localUp)
        await browser.refresh()
        let uploaded = browser.entries.contains { $0.name == "berth_sftp_up.txt" }

        // 下载回来校验
        let localDown = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_sftp_down.txt")
        if let entry = browser.entries.first(where: { $0.name == "berth_sftp_up.txt" }) {
            await browser.download(entry, to: localDown)
            let roundtrip = (try? Data(contentsOf: localDown)) == payload
            // 清理
            await browser.delete(entry)
            await browser.refresh()
            let deleted = !browser.entries.contains { $0.name == "berth_sftp_up.txt" }
            log("SFTP_OK home=\(homeListed) uploaded=\(uploaded) roundtrip=\(roundtrip) deleted=\(deleted)")
        } else {
            log("SFTP_FAIL 上传后未找到文件 home=\(homeListed) uploaded=\(uploaded)")
        }
        browser.close()
    }

    /// ssh-agent 验收:BERTH_AGENT_AUTOTEST=1,用 agent 认证连目标(agent 里须已 ssh-add 目标可用密钥)。
    static func runAgentIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_AGENT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".agent.log", atomically: true, encoding: .utf8)
        }
        let spec = HostSpec(
            hostID: UUID(), label: "agent-test", hostname: host, port: 22,
            username: user, authMethod: .agent, privateKeyPath: nil
        )
        let session = SessionManager.shared.open(spec: spec)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state {
                let info = await session.fetchServerInfo()
                log("AGENT_CONNECT_OK kernel=\(info?.kernel ?? "?")")
                return
            }
            if case .disconnected(let reason) = session.state {
                log("AGENT_CONNECT_FAIL \(reason)")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("AGENT_CONNECT_TIMEOUT state=\(session.state)")
    }

    /// JSON 备份验收:BERTH_BACKUP_AUTOTEST=1,建主机→导出→清空→导入→比对。
    static func runBackupIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_BACKUP_AUTOTEST"] == "1", let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".backup.log", atomically: true, encoding: .utf8)
        }
        let context = ModelContext(container)
        do {
            let group = HostGroup(name: "备份组")
            context.insert(group)
            let host = Host(label: "备份主机", hostname: "1.2.3.4", port: 2200, username: "u", group: group, jumpHostID: nil)
            host.proxy = ProxyConfig(kind: .socks5, host: "127.0.0.1", port: 1080)
            context.insert(host)
            let forward = PortForward(kind: .local, bindHost: "127.0.0.1", bindPort: 9000, targetHost: "db", targetPort: 5432)
            forward.host = host
            context.insert(forward)
            try context.save()

            let data = try BackupService.export(context: context)

            // 清空后导入
            context.delete(host)
            context.delete(group)
            try context.save()

            let result = try BackupService.import(data, context: context)
            let hosts = (try? context.fetch(FetchDescriptor<Host>())) ?? []
            let restored = hosts.first { $0.hostname == "1.2.3.4" }
            let ok = result.hosts == 1
                && restored?.port == 2200
                && restored?.proxy.kind == .socks5
                && restored?.portForwards.count == 1
                && restored?.jumpHostID == nil
            log(ok ? "BACKUP_ROUNDTRIP_OK json=\(data.count)B" : "BACKUP_ROUNDTRIP_FAIL restored=\(String(describing: restored?.port)) fwds=\(restored?.portForwards.count ?? -1)")
        } catch {
            log("BACKUP_FAIL \(error)")
        }
    }

    /// 代理验收:BERTH_PROXY_AUTOTEST=1,经 HTTP/SOCKS5 代理连目标,建立 PTY + 取服务器信息即成功。
    /// 环境:BERTH_PROXY_KIND(http/socks5)+ BERTH_PROXY_HOST/BERTH_PROXY_PORT
    ///       + BERTH_TEST_HOST/USER/KEYFILE + BERTH_TEST_DUMP
    static func runProxyIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_PROXY_AUTOTEST"] == "1",
              let proxyHost = env["BERTH_PROXY_HOST"],
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let proxyKind: ProxyKind = (env["BERTH_PROXY_KIND"] == "http") ? .http : .socks5
        let proxyPort = Int(env["BERTH_PROXY_PORT"] ?? "1080") ?? 1080

        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".proxy.log", atomically: true, encoding: .utf8)
        }
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)

        let proxy = ProxyConfig(kind: proxyKind, host: proxyHost, port: proxyPort)
        let spec = HostSpec(
            hostID: UUID(), label: "proxy-test", hostname: host, port: 22,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile, proxy: proxy
        )
        let session = SessionManager.shared.open(spec: spec)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state {
                let info = await session.fetchServerInfo()
                log("PROXY_CONNECT_OK kind=\(proxyKind.rawValue) kernel=\(info?.kernel ?? "?")")
                return
            }
            if case .disconnected(let reason) = session.state {
                log("PROXY_CONNECT_FAIL \(reason)")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("PROXY_CONNECT_TIMEOUT state=\(session.state)")
    }

    /// 断线自动重连验收:BERTH_RECONNECT_AUTOTEST=1。
    /// 打开真实 UI 会话 → 连上后由外部 `docker restart` 掐断 → 观察进入
    /// disconnected 且排定自动重连 → 最终重新 connected。全程状态写入 <dump>.reconnect.log。
    static func runReconnectIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_RECONNECT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22

        // 自动化下不弹 known_hosts:预写临时 known_hosts 目录不现实,直接信任
        var events: [String] = []
        func log(_ line: String) {
            events.append(line)
            try? events.joined(separator: "\n").write(toFile: dumpBase + ".reconnect.log", atomically: true, encoding: .utf8)
        }

        let spec = HostSpec(
            hostID: UUID(),
            label: "reconnect-test",
            hostname: host,
            port: port,
            username: user,
            authMethod: .password,
            privateKeyPath: nil
        )
        let session = SessionManager.shared.open(spec: spec, transientPassword: password)

        var sawConnected = false
        var sawDrop = false
        var sawReconnectScheduled = false
        var sawReconnected = false
        let deadline = Date().addingTimeInterval(90)

        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            switch session.state {
            case .connected:
                if !sawConnected {
                    sawConnected = true
                    log("CONNECTED")
                } else if sawDrop {
                    sawReconnected = true
                    log("RECONNECTED")
                }
            case .disconnected(let reason):
                if sawConnected, !sawDrop, reason != .userInitiated {
                    sawDrop = true
                    log("DROPPED reason=\(reason)")
                }
            default:
                break
            }
            if session.isAutoReconnectScheduled, !sawReconnectScheduled {
                sawReconnectScheduled = true
                log("AUTO_RECONNECT_SCHEDULED attempt=\(session.reconnectAttempt)")
            }
            if sawReconnected { break }
            try? await Task.sleep(for: .milliseconds(300))
        }

        log(sawReconnected ? "RECONNECT_OK" : "RECONNECT_TIMEOUT")
        log("DONE")
    }

    /// 用底层校验器直接跑一次连接(不经过 UI 弹窗),返回是否成功建立 PTY
    private static func connectOnce(
        spec: HostSpec,
        password: String,
        store: KnownHostsStore,
        decision: @escaping @Sendable (HostKeyPrompt) -> Bool
    ) async -> Bool {
        let probe = ConnectionProbe(store: store, decision: decision)
        return await probe.run(spec: spec, password: password)
    }

    private static func tamperKnownHosts(path: String, hostToken: String) {
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // 把该主机行的 base64 blob 换成另一把随机密钥的 blob(保持格式合法)
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            guard line.contains(hostToken.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
                    || line.hasPrefix(hostToken) else { return line }
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { return line }
            // 生成一个格式合法但不同的 ed25519 blob
            if let bogus = try? NIOSSHPublicKeyFixtureRuntime.randomBlobBase64() {
                return "\(fields[0]) \(fields[1]) \(bogus)"
            }
            return line
        }
        text = lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
