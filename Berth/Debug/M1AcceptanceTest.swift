import Foundation
import SwiftData
import SwiftTerm

/// M1 自动化验收:BERTH_M1_AUTOTEST=1 时执行(配合 BERTH_TRANSIENT_STORE=1 用内存库)。
/// 凭据经环境变量传入而非 argv,避免出现在 ps 输出里。
///   BERTH_TEST_HOST / BERTH_TEST_PORT / BERTH_TEST_USER / BERTH_TEST_PASSWORD / BERTH_TEST_DUMP
/// 流程即里程碑验收标准:新建主机 → 连接 → vim 编辑保存 → cat 校验 → 关闭 → 重连。
@MainActor
enum M1AcceptanceTest {

    static func runIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_M1_AUTOTEST"] == "1",
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

        // 1. Keychain 封装往返自检(一次性账户,同进程读写不触发授权弹窗)
        let probeAccount = "autotest.probe.\(UUID().uuidString)"
        do {
            try KeychainStore.save("s3cret", account: probeAccount)
            let read = try KeychainStore.read(account: probeAccount)
            try KeychainStore.delete(account: probeAccount)
            mark(read == "s3cret" ? "KEYCHAIN_ROUNDTRIP_OK" : "KEYCHAIN_ROUNDTRIP_MISMATCH")
        } catch {
            mark("KEYCHAIN_ROUNDTRIP_FAILED: \(error)")
        }

        // 2. 新建主机,密码走 Keychain 真实链路
        let context = ModelContext(container)
        let record = Host(label: "M1 验收", hostname: host, port: port, username: user)
        context.insert(record)
        do {
            try KeychainStore.save(password, account: KeychainStore.passwordAccount(for: record.id))
            try context.save()
            mark("HOST_CREATED")
        } catch {
            mark("HOST_CREATE_FAILED: \(error)")
            return
        }
        defer { KeychainStore.deleteSecrets(for: record.id) }

        // 3. 连接
        let manager = SessionManager.shared
        let session = manager.open(spec: HostSpec(host: record))
        guard await waitForConnected(session, timeout: 15) else {
            mark("CONNECT_TIMEOUT state=\(session.state)")
            return
        }
        mark("CONNECTED")

        // 4. vim 编辑保存 + cat 校验
        try? await Task.sleep(for: .seconds(1))
        session.sendText("vim /tmp/m1_acceptance.txt\n")
        try? await Task.sleep(for: .seconds(2))
        session.sendText("iM1_VIM_EDIT_OK")
        try? await Task.sleep(for: .seconds(1))
        session.sendText("\u{1b}")
        try? await Task.sleep(for: .milliseconds(500))
        session.sendText(":wq\n")
        try? await Task.sleep(for: .seconds(1.5))
        session.sendText("cat /tmp/m1_acceptance.txt\n")
        try? await Task.sleep(for: .seconds(1.5))
        dump(session, to: dumpBase + ".first")
        mark("FIRST_SESSION_DUMPED")

        // 5. 关闭标签页
        manager.close(session)
        try? await Task.sleep(for: .seconds(1))
        mark(manager.sessions.isEmpty ? "CLOSED" : "CLOSE_FAILED sessions=\(manager.sessions.count)")

        // 6. 重连同一主机,验证上一步 vim 写入的文件仍在
        let second = manager.open(spec: HostSpec(host: record))
        guard await waitForConnected(second, timeout: 15) else {
            mark("RECONNECT_TIMEOUT state=\(second.state)")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        second.sendText("echo RECONNECT_OK && cat /tmp/m1_acceptance.txt\n")
        try? await Task.sleep(for: .seconds(1.5))
        dump(second, to: dumpBase + ".second")
        mark("ALL_DONE")
    }

    private static func waitForConnected(_ session: TerminalSession, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .connected = session.state { return true }
            if case .disconnected = session.state { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func dump(_ session: TerminalSession, to path: String) {
        let terminal = session.terminalView.getTerminal()
        try? terminal.getBufferAsData(kind: .normal).write(to: URL(fileURLWithPath: path + ".normal"))
        try? terminal.getBufferAsData(kind: .alt).write(to: URL(fileURLWithPath: path + ".alt"))
    }
}
