#if DEBUG
import Foundation

/// 半开连接验收:`BERTH_LIVENESS_AUTOTEST=1`。
///
/// 需要一个能被"冻住"的 SSH 服务端 —— 用 docker/test-sshd/fake-sshd.py(asyncssh,
/// 不要 Docker 也不要 root)。冻住进程就是复刻 NAT 会话过期 / 合盖睡眠:内核继续 ACK,
/// SSH 层再也不回话,没有 FIN 也没有 RST,所以被动检测抓不到 —— 正是这次修复要证明的那条路。
/// 拔网线反倒测不到东西,那通常直接送 RST,老路径就能抓到。
///
/// 环境:
///   BERTH_TEST_HOST / BERTH_TEST_PORT / BERTH_TEST_USER / BERTH_TEST_PASSWORD / BERTH_TEST_DUMP
///   BERTH_LIVENESS_FAST=1          静默期从 45s 压到 1s,否则这条验收要真等 45s
///   BERTH_LIVENESS_FREEZE=<路径>   往该文件写 1,fake-sshd 见到就 SIGSTOP 自己
///
/// 期望日志:CONNECTED → FROZE_REQUESTED → KEY_SENT → DISCONNECTED reason=…失效… +
/// RECONNECT_SCHEDULED。修复前的症状是停在 KEY_SENT 之后再没有下文。
@MainActor
enum LivenessAcceptanceTest {

    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_LIVENESS_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22
        let freezeFile = env["BERTH_LIVENESS_FREEZE"]

        let logPath = dumpBase + ".liveness.log"
        var log: [String] = []
        let start = Date()
        func mark(_ step: String) {
            log.append(String(format: "%.1fs ", Date().timeIntervalSince(start)) + step)
            try? log.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }

        let spec = HostSpec(hostID: UUID(), label: "半开验收", hostname: host, port: port,
                            username: user, authMethod: .password, privateKeyPath: nil)
        let session = TerminalSession(spec: spec)
        session.transientPassword = password
        session.connect()

        var connected = false
        for _ in 0..<150 {
            if session.hostKeyPrompt != nil {
                // 首次连接的未知主机密钥:harness 就是"点了信任的用户"
                session.resolveHostKeyPrompt(accepted: true)
                mark("HOSTKEY_TRUSTED")
            }
            if case .connected = session.state { connected = true; break }
            if case .disconnected(let reason) = session.state {
                mark("CONNECT_FAILED reason=\(reason.message ?? "?")")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connected else {
            mark("CONNECT_TIMEOUT state=\(session.state)")
            return
        }
        mark("CONNECTED")

        guard let path = freezeFile else {
            // 不给冻结文件 = 反向验收:服务端一直好好的,不许被误判成死的,
            // 也不许在用户主动断开时弹横幅。这两条错了,修复就变成了新的骚扰。
            try? await Task.sleep(for: .seconds(LivenessTiming.silenceGap + 0.5))
            session.send(source: session.terminalView, data: ArraySlice(Array("echo hi\n".utf8)))
            mark("KEY_SENT_LIVE")
            try? await Task.sleep(for: .seconds(5))
            if case .connected = session.state {
                mark("HEALTHY_STILL_CONNECTED")
            } else {
                mark("FALSE_POSITIVE state=\(session.state) —— 好连接被探测判死了")
            }
            session.disconnect()
            var reason: TerminalSession.DisconnectReason?
            for _ in 0..<50 {
                if case .disconnected(let candidate) = session.state { reason = candidate; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let reason, reason.message == nil {
                mark("USER_INITIATED_QUIET_OK")
            } else {
                mark("USER_INITIATED_SHOWS_BANNER reason=\(String(describing: reason?.message))")
            }
            mark("ALL_DONE mode=healthy")
            return
        }
        try? Data([0x31]).write(to: URL(fileURLWithPath: path))
        mark("FROZE_REQUESTED")

        // 必须真安静:静默期的基准是"距上次有任何动静",提前发一个字节就把窗口重置了
        try? await Task.sleep(for: .seconds(LivenessTiming.silenceGap + 0.5))

        // 走真按键那条路(TerminalViewDelegate.send)。sendText 不经过武装闸门,用它等于没测。
        session.send(source: session.terminalView, data: ArraySlice(Array("echo hi\n".utf8)))
        mark("KEY_SENT")

        var sawReconnect = false
        var verdict = ""
        for _ in 0..<100 {
            if !sawReconnect, session.isAutoReconnectScheduled {
                sawReconnect = true
                mark("RECONNECT_SCHEDULED")
            }
            if case .disconnected(let reason) = session.state {
                verdict = reason.message ?? "(无文案)"
                mark("DISCONNECTED reason=\(verdict)")
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if verdict.isEmpty {
            mark("TIMEOUT_NO_VERDICT state=\(session.state) —— 这就是修复前\"按什么都没反应\"")
        }
        mark("ALL_DONE verdict=\(verdict.isEmpty ? "none" : "ok") reconnectScheduled=\(sawReconnect)")
    }
}
#endif
