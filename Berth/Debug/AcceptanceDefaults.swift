#if DEBUG
import AppKit
import Foundation

/// 自动化验收会直接改真实 defaults(关 Touch ID 门禁、开 AI 自动执行、改本地 shell 路径…),
/// 跑完之后这些削弱安全的设置会静默留在开发机上。带任何 BERTH_ 环境变量启动时先把
/// 持久域整体快照,进程退出时恢复原样;哪怕验收中途失败也不留痕。
enum AcceptanceDefaults {
    private static let lock = NSLock()
    private static var snapshot: [String: Any]?
    private static var domain: String { Bundle.main.bundleIdentifier ?? "com.berthssh.app" }

    static func protectIfAutomated() {
        let env = ProcessInfo.processInfo.environment
        guard env.keys.contains(where: { $0.hasPrefix("BERTH_") }) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard snapshot == nil else { return }
        snapshot = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in restore() }
        atexit { AcceptanceDefaults.restore() }
        // pkill 默认发 SIGTERM,不走 atexit —— 接住它先恢复再退出
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            restore()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    private static var termSource: DispatchSourceSignal?

    static func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let saved = snapshot else { return }
        snapshot = nil
        UserDefaults.standard.setPersistentDomain(saved, forName: domain)
        UserDefaults.standard.synchronize()
    }
}
#endif
