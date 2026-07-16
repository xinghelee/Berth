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
