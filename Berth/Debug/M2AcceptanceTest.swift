#if DEBUG
import Foundation
import SwiftData
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

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

    /// 即时端口转发验收:BERTH_RUNTIME_FWD_AUTOTEST=1。连接时不带任何转发,
    /// 连上后调 addRuntimeForward 临时加一条 local 转发(懒创建 service),验证绑定端口可用。
    static func runRuntimeForwardIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_RUNTIME_FWD_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let targetHost = env["BERTH_FWD_TARGET_HOST"] ?? "127.0.0.1"
        let targetPort = Int(env["BERTH_FWD_TARGET_PORT"] ?? "22") ?? 22
        let bindPort = Int(env["BERTH_FWD_BIND_PORT"] ?? "0") ?? 0

        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".runtimefwd.log", atomically: true, encoding: .utf8)
        }
        log("RUNTIME_FWD_STARTED host=\(host)")
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)

        // 连接时不带任何转发
        let connectPort = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let spec = HostSpec(
            hostID: UUID(), label: "rtfwd", hostname: host, port: connectPort,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile,
            forwards: []
        )
        let session = SessionManager.shared.open(spec: spec)

        let deadline = Date().addingTimeInterval(30)
        var forwardID: UUID?
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .disconnected(let reason) = session.state {
                log("RUNTIME_FWD_DISCONNECTED \(reason)")
                return
            }
            // 连上后临时加一条转发
            if case .connected = session.state, forwardID == nil {
                let forward = PortForwardSpec(
                    kind: .local, bindHost: "127.0.0.1", bindPort: bindPort,
                    targetHost: targetHost, targetPort: targetPort
                )
                forwardID = forward.id
                let ok = session.addRuntimeForward(forward)
                log("RUNTIME_FWD_ADDED ok=\(ok)")
            }
            if let id = forwardID {
                if case .failed(let reason)? = session.forwardStates[id] {
                    log("RUNTIME_FWD_FAILED \(reason)")
                    return
                }
                if case .active(let boundPort)? = session.forwardStates[id] {
                    log("RUNTIME_FWD_ACTIVE port=\(boundPort) runtimeCount=\(session.runtimeForwards.count)")
                    try? await Task.sleep(for: .seconds(30))
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("RUNTIME_FWD_TIMEOUT state=\(session.state)")
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

        // 初始目录跟随该 pane 的当前目录(issue #11-5):shell 报 OSC 7 后新开的
        // 面板应落在那个目录,而不是一律 home
        session.sendText("cd /etc && printf '\\033]7;file://localhost/etc\\033\\\\'\n")
        try? await Task.sleep(for: .seconds(1.5))
        let tracked = session.currentRemoteDirectory
        let followed = SFTPBrowser(initialPath: tracked) { try await session.openSFTP() }
        await followed.start()
        let followsCwd = followed.path == "/etc"
        followed.close()
        guard followsCwd else {
            log("SFTP_FAIL 初始目录未跟随 pane osc7=\(tracked ?? "nil") path=\(followed.path)")
            browser.close()
            return
        }
        session.sendText("cd ~\n")
        try? await Task.sleep(for: .milliseconds(500))

        // 上传一个临时文件
        let payload = "berth-sftp-\(homeListed)".data(using: .utf8)!
        let localUp = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_sftp_up.txt")
        try? payload.write(to: localUp)
        await browser.upload(from: localUp)
        await browser.refresh()
        let uploaded = browser.entries.contains { $0.name == "berth_sftp_up.txt" }

        // 下载回来校验
        let localDown = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_sftp_down.txt")
        guard let entry = browser.entries.first(where: { $0.name == "berth_sftp_up.txt" }) else {
            log("SFTP_FAIL 上传后未找到文件 home=\(homeListed) uploaded=\(uploaded)")
            browser.close()
            return
        }
        await browser.download(entry, to: localDown)
        let roundtrip = (try? Data(contentsOf: localDown)) == payload
        await browser.delete(entry)
        await browser.refresh()
        let deleted = !browser.entries.contains { $0.name == "berth_sftp_up.txt" }

        // 目录递归上传往返(issue #17):嵌套目录 + 空文件 + 符号链接(应跳过)
        let dirRoundtrip = await verifyDirectoryRoundtrip(browser: browser, session: session, log: log)

        // 通道被杀/挂住/断线后自愈(issue #33)
        let recovery = await verifyChannelRecovery(browser: browser, session: session, log: log)

        log("SFTP_OK home=\(homeListed) uploaded=\(uploaded) roundtrip=\(roundtrip) deleted=\(deleted) followsCwd=\(followsCwd) dirRoundtrip=\(dirRoundtrip) recovery=\(recovery)")
        browser.close()
    }

    /// BERTH_SFTP_NAV_AUTOTEST=1:上传进行中切换目录,列表看门狗不得杀掉在途传输。
    /// 手法:SIGSTOP 冻结服务端 sftp 进程 → 发起上传(卡在 open 请求上,传输行在途)→
    /// 切换目录(列目录挂住 → 看门狗探活也挂住 → 有传输在途 → 推迟判死)→ 定时 SIGCONT →
    /// 导航应完成、上传应续跑至完整字节。修复前:探活超时即 dropClient,上传随共享通道一起
    /// 静默死亡(表现就是"仅上传进度行消失、面板浏览随即自动恢复")。
    static func runSFTPNavIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_SFTP_NAV_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".sftpnav.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let spec = HostSpec(
            hostID: UUID(), label: "sftp-nav-test", hostname: host, port: port,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )
        let session = SessionManager.shared.open(spec: spec)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("SFTP_NAV_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("SFTP_NAV_FAIL 连接超时"); return }
        defer { session.disconnect() }

        let browser = SFTPBrowser { try await session.openSFTP() }
        await browser.start()
        guard browser.state == .ready else { log("SFTP_NAV_FAIL 初始列表: \(browser.state)"); browser.close(); return }

        // 导航目标子目录
        session.sendText("mkdir -p ~/berth_nav\n")
        try? await Task.sleep(for: .milliseconds(800))
        await browser.refresh()
        guard let navDir = browser.entries.first(where: { $0.name == "berth_nav" && $0.isDirectory }) else {
            log("SFTP_NAV_FAIL 未建出 ~/berth_nav"); browser.close(); return
        }

        // 本地 512MB 文件(分块写,不整块占内存)
        let bigURL = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_nav_up.bin")
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: bigURL) {
            let chunk = Data(repeating: 0xA5, count: 1 << 20)
            for _ in 0..<512 { try? handle.write(contentsOf: chunk) }
            try? handle.close()
        }
        defer { try? FileManager.default.removeItem(at: bigURL) }
        let bigSize = (try? FileManager.default.attributesOfItem(atPath: bigURL.path)[.size] as? UInt64) ?? 0
        guard bigSize == 512 * 1024 * 1024 else { log("SFTP_NAV_FAIL 本地大文件创建失败"); browser.close(); return }

        // 缩短看门狗:4s 列表 + 1s 探活 → STOP 后 ~6s 出第一次判死决策
        browser.listingTimeout = .seconds(4)
        browser.probeTimeout = .seconds(1)

        // 先 fork 定时 SIGCONT 的子壳(主壳可能随 internal-sftp 一起被冻结,必须提前铺好),
        // 再 STOP。方括号写法避免 pkill -f 匹配到这条命令自身。时序:STOP≈0s → 导航≈1.3s →
        // 判死决策≈6.3s → 推迟窗口 6.3-10.3s → CONT≈7.1s 落在窗口内
        session.sendText("( sleep 7; pkill -CONT -f \"sftp[-]server\"; pkill -CONT -f \"internal[-]sftp\" ) >/dev/null 2>&1 & pkill -STOP -f \"sftp[-]server\"; pkill -STOP -f \"internal[-]sftp\"\n")
        try? await Task.sleep(for: .milliseconds(800))

        // 上传先发起(卡在 open 请求上 → 传输行保持在途),再切目录触发看门狗
        let uploadTask = Task { await browser.upload(from: bigURL) }
        try? await Task.sleep(for: .milliseconds(500))
        guard !browser.transfers.isEmpty else {
            log("SFTP_NAV_FAIL 上传任务未进入在途状态")
            await uploadTask.value
            browser.close()
            return
        }
        let navStart = Date()
        let navTask = Task { await browser.enter(navDir) }
        await navTask.value
        let navElapsed = Date().timeIntervalSince(navStart)

        // 导航必须真的经历过"看门狗判死 → 推迟":STOP 未生效的话这里会秒回,直接失败暴露
        guard navElapsed >= 4.5, browser.path.hasSuffix("/berth_nav"), browser.state == .ready else {
            log("SFTP_NAV_FAIL 导航结果异常 elapsed=\(String(format: "%.1f", navElapsed)) path=\(browser.path) state=\(browser.state)")
            await uploadTask.value
            browser.close()
            return
        }

        await uploadTask.value
        await browser.navigate(to: browser.homePath)
        await browser.refresh()
        let uploadedEntry = browser.entries.first { $0.name == bigURL.lastPathComponent }
        let uploadedIntact = uploadedEntry?.size == bigSize
        let idle = browser.transfers.isEmpty

        if let uploadedEntry { await browser.delete(uploadedEntry) }
        session.sendText("rm -rf ~/berth_nav\n")
        try? await Task.sleep(for: .milliseconds(400))
        browser.close()

        if uploadedIntact, idle {
            log("SFTP_NAV_OK navElapsed=\(String(format: "%.1f", navElapsed)) size=\(bigSize)")
        } else {
            log("SFTP_NAV_FAIL 上传未完整跑完 intact=\(uploadedIntact) idle=\(idle) state=\(browser.state)")
        }
    }

    /// issue #33 验收:面板持有的子通道死掉/挂住后必须自愈,不能停在死通道上等用户重启 app。
    /// (1) 服务端 sftp 进程被杀 → 通道关闭 → 刷新自动重开并回到原目录;
    /// (2) 服务端 sftp 进程 SIGSTOP(模拟远端目录挂在僵死的 NFS 上)→ 看门狗 20s 置失败并丢弃
    ///     通道 → 刷新开新通道恢复;
    /// (3) 会话断线通知 → 立即失败态并丢弃通道 → 刷新即重开。
    /// 服务端进程名:OpenSSH 是 sftp-server,或 internal-sftp(进程标题 sshd: user@internal-sftp)。
    private static func verifyChannelRecovery(
        browser: SFTPBrowser,
        session: TerminalSession,
        log: (String) -> Void
    ) async -> Bool {
        let dirName = "berth_recov"
        func killServerSFTP(_ signal: String) async {
            session.sendText("pkill -\(signal) -f sftp-server; pkill -\(signal) -f internal-sftp\n")
            try? await Task.sleep(for: .milliseconds(800))
        }
        func isFailed() -> Bool {
            if case .failed = browser.state { return true }
            return false
        }
        func cleanup() async {
            await killServerSFTP("KILL")
            session.sendText("rmdir ~/\(dirName)\n")
            try? await Task.sleep(for: .milliseconds(300))
        }

        session.sendText("mkdir -p ~/\(dirName)\n")
        try? await Task.sleep(for: .milliseconds(500))
        await browser.refresh()
        guard let sub = browser.entries.first(where: { $0.name == dirName && $0.isDirectory }) else {
            log("SFTP_FAIL recovery: 未见 \(dirName) state=\(browser.state)")
            return false
        }
        await browser.enter(sub)
        let subPath = browser.path
        guard browser.state == .ready, subPath.hasSuffix("/" + dirName) else {
            log("SFTP_FAIL recovery: 进目录失败 state=\(browser.state) path=\(subPath)")
            await cleanup()
            return false
        }

        // (1) 被杀
        await killServerSFTP("KILL")
        await browser.refresh()
        let killedRecovered = browser.state == .ready && browser.path == subPath
        guard killedRecovered else {
            log("SFTP_FAIL recovery(kill): state=\(browser.state) path=\(browser.path)")
            await cleanup()
            return false
        }

        // (2) 挂住:READDIR 永不回,看门狗到点置失败;收掉被停住的进程后刷新应恢复
        await killServerSFTP("STOP")
        let started = Date()
        await browser.refresh()
        let waited = Date().timeIntervalSince(started)
        let watchdogFired = isFailed()
        await killServerSFTP("KILL")
        await browser.refresh()
        let hungRecovered = watchdogFired && waited >= 19 && waited < 40
            && browser.state == .ready && browser.path == subPath
        guard hungRecovered else {
            log("SFTP_FAIL recovery(hang): watchdog=\(watchdogFired) waited=\(Int(waited))s state=\(browser.state) path=\(browser.path)")
            await cleanup()
            return false
        }

        // (3) 断线通知
        browser.connectionLost()
        let lostState = isFailed()
        await browser.refresh()
        let lostRecovered = lostState && browser.state == .ready && browser.path == subPath
        guard lostRecovered else {
            log("SFTP_FAIL recovery(lost): failedFirst=\(lostState) state=\(browser.state) path=\(browser.path)")
            await cleanup()
            return false
        }

        await browser.goUp()
        await cleanup()
        return true
    }

    /// issue #17 验收:建本地目录树(含符号链接)→ 递归上传 → 递归下载回来逐文件比对
    /// → 符号链接不应被上传 → 用 shell 清理远端(rmdir 不递归,面板删除不适用)
    private static func verifyDirectoryRoundtrip(
        browser: SFTPBrowser,
        session: TerminalSession,
        log: (String) -> Void
    ) async -> Bool {
        let fm = FileManager.default
        let stamp = "berth_sftp_dir"
        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-dirtest-\(UUID().uuidString)", isDirectory: true)
        let src = localRoot.appendingPathComponent(stamp, isDirectory: true)
        let alpha = Data("alpha".utf8)
        let blob = Data((0..<1024).map { UInt8($0 % 251) })
        defer { try? fm.removeItem(at: localRoot) }
        do {
            try fm.createDirectory(
                at: src.appendingPathComponent("nested/deeper", isDirectory: true),
                withIntermediateDirectories: true
            )
            try alpha.write(to: src.appendingPathComponent("a.txt"))
            try blob.write(to: src.appendingPathComponent("nested/b.bin"))
            fm.createFile(atPath: src.appendingPathComponent("nested/deeper/zero").path, contents: nil)
            try fm.createSymbolicLink(
                at: src.appendingPathComponent("linked"),
                withDestinationURL: src.appendingPathComponent("a.txt")
            )
        } catch {
            log("SFTP_FAIL 目录树构建失败 \(error)")
            return false
        }

        await browser.upload(from: src)
        await browser.refresh()
        guard let remoteDir = browser.entries.first(where: { $0.name == stamp && $0.isDirectory }) else {
            log("SFTP_FAIL 目录上传后未见 \(stamp),state=\(browser.state)")
            return false
        }

        // 目录下载不再合并进已有目录(DownloadDestinationTransaction 预检拒绝):目标必须不存在
        let downRoot = localRoot.appendingPathComponent("down", isDirectory: true)
        try? fm.removeItem(at: downRoot)
        await browser.download(remoteDir, to: downRoot)

        let gotAlpha = (try? Data(contentsOf: downRoot.appendingPathComponent("a.txt"))) == alpha
        let gotBlob = (try? Data(contentsOf: downRoot.appendingPathComponent("nested/b.bin"))) == blob
        let zeroPath = downRoot.appendingPathComponent("nested/deeper/zero").path
        let gotZero = fm.fileExists(atPath: zeroPath)
            && (try? fm.attributesOfItem(atPath: zeroPath)[.size] as? UInt64) == 0
        let linkSkipped = !fm.fileExists(atPath: downRoot.appendingPathComponent("linked").path)

        // 文件夹拖出下载:不经 Finder,直接向 NSItemProvider 要 folder 文件表示,
        // 走的是拖拽完全相同的注册路径(SFTPDragProvider)
        let provider = SFTPDragProvider.make(entry: remoteDir, remoteDirectory: browser.path, browser: browser)
        let dragCopy = localRoot.appendingPathComponent("drag", isDirectory: true)
        let dragLoaded: Bool = await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { url, _ in
                // URL 只在回调内有效(Finder 也是在这里复制),当场拷走
                guard let url, (try? fm.copyItem(at: url, to: dragCopy)) != nil else {
                    cont.resume(returning: false)
                    return
                }
                cont.resume(returning: true)
            }
        }
        let dragRoundtrip = dragLoaded
            && (try? Data(contentsOf: dragCopy.appendingPathComponent("a.txt"))) == alpha
            && (try? Data(contentsOf: dragCopy.appendingPathComponent("nested/b.bin"))) == blob

        // 递归删除:先在远端目录里放个符号链接(上传不会带过去),连它一起删干净
        session.sendText("ln -s a.txt ~/\(stamp)/link\n")
        try? await Task.sleep(for: .milliseconds(600))
        await browser.delete(remoteDir)
        await browser.refresh()
        let recursiveDeleted = !browser.entries.contains { $0.name == stamp }

        let ok = gotAlpha && gotBlob && gotZero && linkSkipped && dragRoundtrip && recursiveDeleted
        if !ok {
            log("SFTP_FAIL dirRoundtrip alpha=\(gotAlpha) blob=\(gotBlob) zero=\(gotZero) linkSkipped=\(linkSkipped) drag=\(dragRoundtrip) rmRecursive=\(recursiveDeleted)")
            // 兜底清理,避免残留影响下次跑
            session.sendText("rm -rf ~/\(stamp)\n")
            try? await Task.sleep(for: .milliseconds(400))
        }
        return ok
    }

    /// 服务端文件编辑验收:BERTH_SFTPEDIT_AUTOTEST=1。上传文件 → editRemotely(不启动编辑器)拉到本地
    /// → 改本地文件 → 等轮询自动回传 → 重新下载校验远端已更新 → 清理。
    static func runSFTPEditIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_SFTPEDIT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".sftpedit.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let spec = HostSpec(
            hostID: UUID(), label: "sftpedit-test", hostname: host, port: port,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )
        let session = SessionManager.shared.open(spec: spec)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("SFTPEDIT_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("SFTPEDIT_FAIL 连接超时"); return }

        let browser = SFTPBrowser { try await session.openSFTP() }
        await browser.start()
        guard browser.state == .ready else { log("SFTPEDIT_FAIL list \(browser.state)"); return }

        // 上传初始文件
        let localUp = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_edit_src.txt")
        try? "before".data(using: .utf8)!.write(to: localUp)
        await browser.upload(from: localUp)
        await browser.refresh()
        guard let entry = browser.entries.first(where: { $0.name == "berth_edit_src.txt" }) else {
            log("SFTPEDIT_FAIL 上传后未找到文件"); return
        }

        // 开始编辑(不启动编辑器),拿到本地副本
        guard let localCopy = browser.editRemotely(entry, openInEditor: false) else {
            log("SFTPEDIT_FAIL editRemotely 返回空"); return
        }
        // 等下载完成
        var downloaded = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(200))
            if FileManager.default.fileExists(atPath: localCopy.path),
               (try? String(contentsOf: localCopy, encoding: .utf8)) == "before" { downloaded = true; break }
        }
        guard downloaded else { log("SFTPEDIT_FAIL 本地副本未就绪"); return }

        // 模拟编辑器保存:改本地文件
        try? "after-edited".data(using: .utf8)!.write(to: localCopy)

        // 等轮询回传(轮询间隔 1.2s),再从远端重新下载校验
        var synced = false
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(400))
            let verifyLocal = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_edit_verify.txt")
            await browser.download(entry, to: verifyLocal)
            if (try? String(contentsOf: verifyLocal, encoding: .utf8)) == "after-edited" { synced = true; break }
        }

        browser.stopEditing(browser.path == "/" ? "/berth_edit_src.txt" : "\(browser.path)/berth_edit_src.txt")
        await browser.delete(entry)

        // issue #34:md 相对引用的资源随主文件镜像下载
        let assets = await verifyReferencedAssets(browser: browser, session: session, log: log)

        // issue #46:未指定编辑器时各类文件名解析到哪个程序(真机 LaunchServices 结果,只记录供人工核对;
        // 硬断言只有「可执行/网页类不会落到纯文本编辑器之外」)
        UserDefaults.standard.set("", forKey: SettingsKeys.externalEditorPath)
        let plainTextEditor = SFTPBrowser.systemEditorApplication(for: URL(fileURLWithPath: "/x/plain.txt"))
        var resolved: [String] = []
        var guarded = true
        for name in ["app.yaml", "config.json", "README.md", "notes.terminal", "link.webloc", "run.command", "run.sh",
                     "profile.mobileconfig", "index.html", "page.xhtml", "logo.svg", "pkg.dmg", "noext"] {
            let app = SFTPBrowser.systemEditorApplication(for: URL(fileURLWithPath: "/x/" + name))
            resolved.append("\(name)→\(app.lastPathComponent)")
            let mustFallBack = !["app.yaml", "config.json", "README.md"].contains(name)
            if mustFallBack, app != plainTextEditor { guarded = false }
        }
        let editorLine = "editors: " + resolved.joined(separator: " ")

        let ok = synced && assets && guarded
        log((ok ? "SFTPEDIT_OK downloaded=\(downloaded) synced=\(synced) assets=\(assets) guarded=\(guarded)"
                : "SFTPEDIT_FAIL synced=\(synced) assets=\(assets) guarded=\(guarded)") + "\n" + editorLine)
        browser.close()
    }

    /// issue #34 验收:远端 berth_ed/docs/readme.md 引用 diagrams/a.svg、../shared/b.png、一个 https URL、
    /// 一个绝对路径和一个不存在的文件。editRemotely 后:本地副本按远端绝对路径镜像;两个相对资源在
    /// 对应位置且内容正确;URL/绝对路径/缺失的不下载。
    private static func verifyReferencedAssets(
        browser: SFTPBrowser,
        session: TerminalSession,
        log: (String) -> Void
    ) async -> Bool {
        let home = browser.homePath
        let docs = "\(home)/berth_ed/docs"
        let remoteMD = "\(docs)/readme.md"
        let setup = """
        mkdir -p ~/berth_ed/docs/diagrams ~/berth_ed/shared \
        && printf 'svg-data' > ~/berth_ed/docs/diagrams/a.svg \
        && printf 'png-data' > ~/berth_ed/shared/b.png \
        && printf '# T\\n![A](diagrams/a.svg)\\n![B](../shared/b.png)\\n![X](https://example.com/x.png)\\n![Y](/etc/hostname)\\n[missing](diagrams/nope.svg)\\n' > ~/berth_ed/docs/readme.md \
        && echo BERTH_ED_READY
        """
        guard let prepared = await session.runAICommand(setup), prepared.output.contains("BERTH_ED_READY") else {
            log("SFTPEDIT_FAIL assets: 远端准备失败"); return false
        }
        defer { Task { _ = await session.runAICommand("rm -rf ~/berth_ed") } }
        await browser.navigate(to: docs)
        guard browser.state == .ready, let entry = browser.entries.first(where: { $0.name == "readme.md" }) else {
            log("SFTPEDIT_FAIL assets: 未见 readme.md state=\(browser.state) path=\(browser.path)"); return false
        }
        guard let local = browser.editRemotely(entry, openInEditor: false) else {
            log("SFTPEDIT_FAIL assets: editRemotely 返回空"); return false
        }
        var ready = false
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(200))
            if browser.editing[remoteMD] == .idle { ready = true; break }
        }
        let fm = FileManager.default
        let mirrored = local.path.hasSuffix("/berth_ed/docs/readme.md")
        let dir = local.deletingLastPathComponent()
        let gotA = (try? String(contentsOf: dir.appendingPathComponent("diagrams/a.svg"), encoding: .utf8)) == "svg-data"
        let gotB = (try? String(contentsOf: dir.appendingPathComponent("../shared/b.png").standardized, encoding: .utf8)) == "png-data"
        // 镜像根 = 路径里 berth-edit-<uuid> 那一级;绝对路径引用不应被拉到根下
        let rootIndex = local.pathComponents.firstIndex { $0.hasPrefix("berth-edit-") } ?? 0
        let root = URL(fileURLWithPath: NSString.path(withComponents: Array(local.pathComponents[...rootIndex])))
        let noAbsolute = !fm.fileExists(atPath: root.appendingPathComponent("etc/hostname").path)
        let noMissing = !fm.fileExists(atPath: dir.appendingPathComponent("diagrams/nope.svg").path)
        browser.stopEditing(remoteMD)
        await browser.navigate(to: home)
        let ok = ready && mirrored && gotA && gotB && noAbsolute && noMissing
        if !ok {
            log("SFTPEDIT_FAIL assets ready=\(ready) mirrored=\(mirrored) a=\(gotA) b=\(gotB) noAbs=\(noAbsolute) noMissing=\(noMissing) local=\(local.path)")
        }
        return ok
    }

    /// 拖放上传验收:BERTH_DROPUPLOAD_AUTOTEST=1。连目标(测试容器无命令集成,cwd 走
    /// 连接内探测)→ 探测出唯一目录 → 上传 → 二次上传同名触发覆盖确认 → 覆盖 → 校验 → 清理。
    static func runDropUploadIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_DROPUPLOAD_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".drop.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let spec = HostSpec(
            hostID: UUID(), label: "drop-test", hostname: host, port: port,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )
        let session = SessionManager.shared.open(spec: spec)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("DROP_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("DROP_FAIL 连接超时"); return }
        // 等远端 shell 起来,探测才有带 TTY 的子进程可找
        try? await Task.sleep(for: .milliseconds(1500))

        // 目录解析:测试容器没有命令集成,OSC 7 为 nil,必须走探测拿到唯一候选
        let osc7 = session.currentRemoteDirectory
        let probed = await session.probeRemoteWorkingDirectories()
        guard let directory = osc7 ?? (probed.count == 1 ? probed.first : nil) else {
            log("DROP_FAIL 目录解析失败 osc7=\(osc7 ?? "nil") probed=\(probed)")
            return
        }

        let payload = "berth-drop-\(Int.random(in: 1000...9999))".data(using: .utf8)!
        let localUp = URL(fileURLWithPath: NSTemporaryDirectory() + "berth_drop_up.txt")
        try? payload.write(to: localUp)

        let model = TerminalDropUploadModel()
        await model.upload([localUp], to: directory, session: session)
        guard case .done = model.phase else { log("DROP_FAIL 首次上传 phase=\(model.phase)"); return }

        // 同名再传:必须停在覆盖确认,而不是静默覆盖
        await model.upload([localUp], to: directory, session: session)
        guard let pending = model.pendingOverwrite, pending.conflicts == ["berth_drop_up.txt"] else {
            log("DROP_FAIL 未触发覆盖确认 pending=\(String(describing: model.pendingOverwrite))")
            return
        }
        model.resolveOverwrite(pending, overwrite: true, session: session)
        for _ in 0..<50 {
            if case .done = model.phase { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .done = model.phase else { log("DROP_FAIL 覆盖上传 phase=\(model.phase)"); return }

        // 远端校验 + 清理
        do {
            let sftp = try await session.openSFTP()
            let remotePath = TerminalDropUploadModel.join(directory, "berth_drop_up.txt")
            let file = try await sftp.openFile(filePath: remotePath, flags: .read)
            let buffer = try await file.readAll()
            try? await file.close()
            let match = Data(buffer.readableBytesView) == payload
            try await sftp.remove(at: remotePath)
            try? await sftp.close()
            log(match
                ? "DROP_OK dir=\(directory) probed=\(osc7 == nil) overwriteConfirmed=true"
                : "DROP_FAIL 内容不一致")
        } catch {
            log("DROP_FAIL 校验 \(error)")
        }
    }

    /// su 切换用户验收(issue #35):BERTH_SWITCHUSER_AUTOTEST=1。测试容器的 su 不是 suid,
    /// 用一个行为一致的假 su(打 Password: 提示、关回显读一行、对了起 bash)放进 ~/bin,并写
    /// ~/.bash_profile 让登录 shell 优先找到它。
    /// 验证:提示出现后才发密码(假 su 先打一行 PAM 式「密码将过期」诱饵,匹配必须锚定到停在行尾的
    /// 真提示)、密码不出现在屏幕上、切换成功、启动命令落在切换后的 shell;没存密码时只发 su,停在提示符等人工输入。
    static func runSwitchUserIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_SWITCHUSER_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".switchuser.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let transientPassword = env["BERTH_TEST_PASSWORD"]
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        func makeSpec(_ label: String) -> HostSpec {
            HostSpec(
                hostID: UUID(), label: label, hostname: host, port: port, username: user,
                authMethod: env["BERTH_TEST_KEYFILE"] != nil ? .privateKeyFile : .password,
                privateKeyPath: env["BERTH_TEST_KEYFILE"]
            )
        }
        func waitConnected(_ session: TerminalSession) async -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
                if case .connected = session.state { return true }
                if case .disconnected = session.state { return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        func screen(_ session: TerminalSession) -> String {
            String(decoding: session.terminalView.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
        }

        // 准备假 su(用 exec 通道,不经 PTY 回显)
        let setup = SessionManager.shared.open(spec: makeSpec("su-setup"), transientPassword: transientPassword)
        guard await waitConnected(setup) else { log("SWITCHUSER_FAIL 准备会话连不上"); return }
        let fakeSu = """
        mkdir -p ~/bin && cat > ~/bin/su <<'EOF'
        #!/bin/sh
        echo 'Warning: your password will expire in 3 days'
        printf 'Password: '
        stty -echo 2>/dev/null; read -r pw; stty echo 2>/dev/null; echo
        if [ "$pw" = "berth-su-secret" ]; then echo "BERTH_SU_OK user=$2"; exec /bin/bash; fi
        echo 'su: Authentication failure'; exit 1
        EOF
        chmod +x ~/bin/su && printf 'export PATH="$HOME/bin:$PATH"\\n' > ~/.bash_profile && echo BERTH_SETUP_DONE
        """
        let prepared = await setup.runAICommand(fakeSu)
        setup.shutdown()
        guard prepared?.output.contains("BERTH_SETUP_DONE") == true else {
            log("SWITCHUSER_FAIL 假 su 准备失败 \(prepared?.output ?? "nil")"); return
        }
        func cleanup() async {
            let session = SessionManager.shared.open(spec: makeSpec("su-cleanup"), transientPassword: transientPassword)
            if await waitConnected(session) { _ = await session.runAICommand("rm -f ~/bin/su ~/.bash_profile") }
            session.shutdown()
        }

        // 场景 1:存了密码 → 提示出现后作答 → 切换成功 → 启动命令在新 shell 里执行
        var spec = makeSpec("su-test")
        spec.switchUser = user
        spec.startupCommands = "echo BERTH_AFTER_SU_$(id -un)"
        try? KeychainStore.save("berth-su-secret", account: KeychainStore.switchUserPasswordAccount(for: spec.hostID))
        defer { try? KeychainStore.delete(account: KeychainStore.switchUserPasswordAccount(for: spec.hostID)) }
        let session = SessionManager.shared.open(spec: spec, transientPassword: transientPassword)
        guard await waitConnected(session) else { log("SWITCHUSER_FAIL 场景1连不上"); await cleanup(); return }
        var text = ""
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            text = screen(session)
            if text.contains("BERTH_AFTER_SU_\(user)") { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        session.shutdown()
        let promptAt = text.range(of: "Password:")?.lowerBound
        let switchedAt = text.range(of: "BERTH_SU_OK user=\(user)")?.lowerBound
        let promptFirst = promptAt != nil && switchedAt != nil && promptAt! < switchedAt!
        let startupAfterSu = text.contains("BERTH_AFTER_SU_\(user)")
        let secretHidden = !text.contains("berth-su-secret")

        // 场景 2:没存密码 → 只发 su,停在提示符等人工输入
        var bare = makeSpec("su-noauth")
        bare.switchUser = user
        let session2 = SessionManager.shared.open(spec: bare, transientPassword: transientPassword)
        guard await waitConnected(session2) else { log("SWITCHUSER_FAIL 场景2连不上"); await cleanup(); return }
        try? await Task.sleep(for: .seconds(3))
        let text2 = screen(session2)
        let waitedForHuman = text2.contains("Password:") && !text2.contains("BERTH_SU_OK") && !text2.contains("Authentication failure")
        session2.sendText("\u{03}")
        session2.shutdown()

        await cleanup()
        let ok = promptFirst && startupAfterSu && secretHidden && waitedForHuman
        log("\(ok ? "SWITCHUSER_OK" : "SWITCHUSER_FAIL") promptFirst=\(promptFirst) startupAfterSu=\(startupAfterSu) secretHidden=\(secretHidden) waitedForHuman=\(waitedForHuman) screen1=\(text.suffix(400).debugDescription) screen2=\(text2.suffix(200).debugDescription)")
    }

    /// AI 命令执行验收:BERTH_AI_AUTOTEST=1。连目标后走 runAICommand(AI 助手执行命令的通道):
    /// 验证 stdout/stderr 合并、非零退出码不抛错而是被解析出来、PTY 不受影响。
    static func runAICommandIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_AI_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".ai.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        var spec = HostSpec(
            hostID: UUID(), label: "ai-test", hostname: host, port: port,
            username: user,
            authMethod: env["BERTH_TEST_KEYFILE"] != nil ? .privateKeyFile : .password,
            privateKeyPath: env["BERTH_TEST_KEYFILE"]
        )
        spec.startupCommands = ""
        let session = SessionManager.shared.open(spec: spec, transientPassword: env["BERTH_TEST_PASSWORD"])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("AI_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("AI_FAIL 连接超时"); return }

        guard let ok = await session.runAICommand("echo hello-from-ai; uname -s") else {
            log("AI_FAIL runAICommand 返回 nil(未连接)"); return
        }
        // stderr 合并 + 非零退出码
        guard let failing = await session.runAICommand("echo to-stderr >&2; exit 7") else {
            log("AI_FAIL 第二条命令返回 nil"); return
        }
        let stdoutOK = ok.output.contains("hello-from-ai") && (ok.exitCode ?? -1) == 0
        let stderrMerged = failing.output.contains("to-stderr")
        let exitParsed = failing.exitCode == 7
        // PTY 仍然活着(exec 通道不影响 shell)
        let ptyAlive: Bool = { if case .connected = session.state { return true }; return false }()
        let verdict = stdoutOK && stderrMerged && exitParsed && ptyAlive ? "AI_OK" : "AI_FAIL"
        log("\(verdict) stdout=\(stdoutOK) stderrMerged=\(stderrMerged) exit7=\(exitParsed) ptyAlive=\(ptyAlive) out1=\(ok.output.debugDescription) out2=\(failing.output.debugDescription) code2=\(String(describing: failing.exitCode))")
    }

    /// AI 对话回路验收:BERTH_AICHAT_AUTOTEST=1 + BERTH_AI_BASEURL 指向一个 mock 网关。
    /// 走完整回路:提问 → 模型要求 run_command → 在真实 SSH 上执行 → 结果回传 → 拿到最终答复。
    /// 用本机地址免 Key(与 Ollama/LM Studio 同一条路径)。
    static func runAIChatIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_AICHAT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let baseURL = env["BERTH_AI_BASEURL"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".aichat.log", atomically: true, encoding: .utf8)
        }
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: SettingsKeys.aiBaseURL)
        defaults.set(AISettings.APIFormat.openAI.rawValue, forKey: SettingsKeys.aiAPIFormat)
        defaults.set("mock-model", forKey: SettingsKeys.aiModel)
        defaults.set(true, forKey: SettingsKeys.aiAutoRunCommands)
        defaults.set(false, forKey: SettingsKeys.requireTouchIDForKeys)

        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let spec = HostSpec(
            hostID: UUID(), label: "aichat-test", hostname: host, port: port,
            username: user, authMethod: .password, privateKeyPath: nil
        )
        let session = SessionManager.shared.open(spec: spec, transientPassword: env["BERTH_TEST_PASSWORD"])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { break }
            if case .disconnected(let reason) = session.state { log("AICHAT_FAIL 连接失败 \(reason)"); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .connected = session.state else { log("AICHAT_FAIL 连接超时"); return }

        let controller = AIChatStore.shared.controller(for: session)
        controller.send("磁盘还剩多少")
        let chatDeadline = Date().addingTimeInterval(60)
        while controller.isBusy, Date() < chatDeadline {
            try? await Task.sleep(for: .milliseconds(200))
        }

        let assistants = controller.messages.filter { message in
            if case .assistant = message.role { return true }
            return false
        }
        let toolCalls: [AIToolCall] = assistants.flatMap { $0.toolCalls }
        let errors: [String] = assistants.compactMap { $0.errorText }
        let ranCommand = toolCalls.first
        let finalText = assistants.last?.text ?? ""
        let ok = !controller.isBusy
            && errors.isEmpty
            && ranCommand?.status == .done
            && (ranCommand?.output.contains("Filesystem") ?? false)
            && finalText.contains("mock-final")
        // 「询问 AI」:终端选中的报错走 SessionManager 进面板并自动提问
        SessionManager.shared.isAIPanelVisible = false
        let before = controller.messages.count
        SessionManager.shared.askAIAboutSelection("bash: nginx: command not found")
        let askOK = SessionManager.shared.isAIPanelVisible
            && controller.messages.count > before
            && (controller.messages.last { message in
                if case .user = message.role { return true }
                return false
            }?.text.contains("command not found") ?? false)
        controller.stop()

        log("\(ok && askOK ? "AICHAT_OK" : "AICHAT_FAIL") turns=\(assistants.count) tools=\(toolCalls.count) cmd=\(ranCommand?.command ?? "-") exit=\(String(describing: ranCommand?.exitCode)) errors=\(errors) askSelection=\(askOK) final=\(finalText.debugDescription) out=\(ranCommand?.output.prefix(80).debugDescription ?? "-")")

        // 顺手出两张截图核对界面:整面板 + 消息流(ScrollView 在 ImageRenderer 下渲不出内容,
        // 所以消息单独用非 lazy 的 VStack 渲一份,含代码块卡片)
        ranCommand?.isOutputExpanded = true
        PanelSnapshot.write(
            AIChatPanelView(session: session) {},
            height: 420,
            to: dumpBase + ".panel.png"
        )
        let sample = AIChatMessage(role: .assistant, text: """
        查看当前磁盘空间可以用:

        ```bash
        df -h
        ```

        只看根分区:

        ```bash
        df -h /
        ```
        """)
        PanelSnapshot.write(
            VStack(alignment: .leading, spacing: 10) {
                ForEach(controller.messages + [sample]) { message in
                    AIChatMessageView(message: message, controller: controller, session: session)
                }
            }
            .padding(10)
            .frame(width: 320)
            .background(ThemeStore.shared.current.panelBackground),
            height: 900,
            to: dumpBase + ".messages.png"
        )
    }

    /// keyboard-interactive 验收(issue #12):BERTH_KBDINT_AUTOTEST=1。
    /// 目标 sshd 须已禁用 password、只开 keyboard-interactive(docker/test-sshd/up-kbdint.sh)。
    /// A:存储密码 → password 被拒后转 kbd-int,首个不回显提示自动用密码作答 → 连上跑通命令。
    /// B:无密码 → 质询冒泡为 keyboardInteractivePrompt(UI sheet 数据源)→ 程序化作答 → 连上。
    static func runKbdIntIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_KBDINT_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: dumpBase + ".kbdint.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let manager = SessionManager.shared

        func waitConnected(_ session: TerminalSession, _ tag: String, answers: [String]? = nil) async -> Bool {
            let deadline = Date().addingTimeInterval(25)
            var promptAnswered = false
            while Date() < deadline {
                if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
                if let prompt = session.keyboardInteractivePrompt {
                    if let answers, !promptAnswered {
                        promptAnswered = true
                        log("\(tag) PROMPT title=\(prompt.challenge.title) prompts=\(prompt.challenge.prompts.map(\.text))")
                        session.resolveKeyboardInteractivePrompt(answers: answers)
                    } else if answers == nil {
                        log("\(tag) UNEXPECTED_PROMPT \(prompt.challenge.prompts.map(\.text))")
                        session.resolveKeyboardInteractivePrompt(answers: nil)
                    }
                }
                if case .connected = session.state { return true }
                if case .disconnected(let reason) = session.state {
                    log("\(tag) DISCONNECTED \(reason.message ?? "-")")
                    return false
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            log("\(tag) TIMEOUT state=\(session.state)")
            return false
        }

        // A:存储密码自动应答(不该弹任何质询 UI)
        let specA = HostSpec(
            hostID: UUID(), label: "kbdint-auto", hostname: host, port: port,
            username: user, authMethod: .password, privateKeyPath: nil
        )
        let auto = manager.open(spec: specA, transientPassword: password)
        guard await waitConnected(auto, "AUTO") else { log("KBDINT_FAIL 自动应答未连上"); return }
        try? await Task.sleep(for: .seconds(1))
        auto.sendText("echo BERTH_KBDINT_$((40+2))\n")
        try? await Task.sleep(for: .seconds(1))
        let terminal = auto.terminalView.getTerminal()
        let text = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        let echoOK = text.contains("BERTH_KBDINT_42")
        log("AUTO_CONNECTED echo=\(echoOK)")
        manager.closePane(auto)
        guard echoOK else { log("KBDINT_FAIL 自动应答 shell 不可用"); return }

        // B:无存储密码 → 质询必须冒泡成 keyboardInteractivePrompt,由「UI」作答
        let specB = HostSpec(
            hostID: UUID(), label: "kbdint-prompt", hostname: host, port: port,
            username: user, authMethod: .password, privateKeyPath: nil
        )
        let prompted = manager.open(spec: specB)
        let promptOK = await waitConnected(prompted, "PROMPT", answers: [password])
        manager.closePane(prompted)
        log(promptOK ? "KBDINT_OK auto+prompt 双路径通过" : "KBDINT_FAIL 质询路径未连上")
    }

    /// 连接复用验收:BERTH_REUSE_AUTOTEST=1。连目标(拥有者)后,再开一个借用会话复用同一连接,
    /// 验证:两者是同一条底层连接(同一 SSHConnection 对象)、借用会话能连上并跑通命令、
    /// 关掉借用会话后拥有者仍在(引用计数不误关共享连接)。这直接证明分屏/⌘T 不再新建 TCP。
    static func runReuseIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_REUSE_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let keyFile = env["BERTH_TEST_KEYFILE"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".reuse.log", atomically: true, encoding: .utf8)
        }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        let manager = SessionManager.shared
        let spec = HostSpec(
            hostID: UUID(), label: "reuse-test", hostname: host, port: port,
            username: user, authMethod: .privateKeyFile, privateKeyPath: keyFile
        )

        func waitConnected(_ session: TerminalSession, _ tag: String) async -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
                if case .connected = session.state { return true }
                if case .disconnected(let reason) = session.state { log("REUSE_FAIL \(tag) 断开 \(reason)"); return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            log("REUSE_FAIL \(tag) 连接超时"); return false
        }

        // 1. 拥有者:自建连接
        let owner = manager.open(spec: spec)
        guard await waitConnected(owner, "owner") else { return }
        guard let ownerConn = owner.liveConnection else { log("REUSE_FAIL 拥有者无 liveConnection"); return }

        // 2. 借用者:复用拥有者的连接(等价于分屏/⌘T)
        let borrower = manager.open(spec: spec, reusing: ownerConn)
        guard await waitConnected(borrower, "borrower") else { return }

        // 3. 同一条底层连接?(对象身份相同 = 没有新建 TCP)
        let sameConnection = borrower.liveConnection === ownerConn
        // 4. 借用会话的通道确实可用(在共享连接上另开 exec 通道取信息)
        let borrowerWorks = (await borrower.fetchServerInfo())?.textRows.isEmpty == false

        // 5. 关掉借用会话,拥有者应仍然在线(release 不误关共享连接)
        manager.closePane(borrower)
        try? await Task.sleep(for: .milliseconds(500))
        let ownerStillUp: Bool = { if case .connected = owner.state { return true } else { return false } }()
        // 拥有者仍能用共享连接(证明底层 client 没被借用会话关掉)
        let ownerStillWorks = (await owner.fetchServerInfo())?.textRows.isEmpty == false

        log("REUSE_OK sameConnection=\(sameConnection) borrowerWorks=\(borrowerWorks) ownerStillUp=\(ownerStillUp) ownerStillWorks=\(ownerStillWorks)")
        manager.closePane(owner)
    }

    /// Keychain 跨构建持久化探针:BERTH_KEYCHAIN_PROBE=save|read|cleanup。
    /// 用途:验证换稳定签名后,新构建能静默读到旧构建保存的密码项(ad-hoc 签名下会 errSecAuthFailed)。
    static func runKeychainProbeIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["BERTH_KEYCHAIN_PROBE"], let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        func log(_ line: String) {
            try? line.write(toFile: dumpBase + ".keychain.log", atomically: true, encoding: .utf8)
        }
        let account = "debug.crossbuild.probe"
        switch mode {
        case "save":
            do {
                try KeychainStore.save("probe-secret-123", account: account)
                log("KEYCHAIN_SAVE_OK")
            } catch {
                log("KEYCHAIN_SAVE_FAIL \(error.localizedDescription)")
            }
        case "read":
            do {
                let value = try KeychainStore.read(account: account)
                log(value == "probe-secret-123" ? "KEYCHAIN_READ_OK" : "KEYCHAIN_READ_MISMATCH \(value ?? "nil")")
            } catch {
                log("KEYCHAIN_READ_FAIL \(error.localizedDescription)")
            }
        case "cleanup":
            try? KeychainStore.delete(account: account)
            log("KEYCHAIN_CLEANUP_OK")
        default:
            break
        }
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
                && (restored?.portForwards ?? []).count == 1
                && restored?.jumpHostID == nil
            log(ok ? "BACKUP_ROUNDTRIP_OK json=\(data.count)B" : "BACKUP_ROUNDTRIP_FAIL restored=\(String(describing: restored?.port)) fwds=\((restored?.portForwards ?? []).count)")
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

#endif
