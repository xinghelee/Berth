import Citadel
import Foundation

/// 一条真实 SSH 连接(含跳板链)的共享持有者,引用计数管理生命周期。
///
/// 多个 `TerminalSession`(⌘T 复制当前连接、⌘D 分屏)复用同一条连接,各自在其上
/// 开独立的 PTY 通道 —— 等价于 OpenSSH 的 ControlMaster 连接复用。这样对同一主机
/// 不再高频新建 TCP 连接,避免触发 OpenSSH 9.8+ 的 PerSourcePenalties(源 IP 因短时间
/// 大量独立连接被临时封禁,连接在握手前即被关闭)。
///
/// 引用归零(拥有者与所有借用会话都结束)才真正关闭底层 client 及跳板隧道。
@MainActor
final class SSHConnection {
    let client: SSHClient
    /// 跳板链上的中间 client,必须保活以维持隧道;关闭时由内到外一并关闭
    private let jumpClients: [SSHClient]
    private var refCount = 0
    private var closed = false

    init(client: SSHClient, jumpClients: [SSHClient]) {
        self.client = client
        self.jumpClients = jumpClients
    }

    /// 底层连接是否仍可用(未被引用归零关闭)。注意:探测不了远端/网络层已断但本地未 release 的情况。
    var isAlive: Bool { !closed }

    func retain() { refCount += 1 }

    /// 释放一个引用;归零即真正关闭底层连接。幂等。
    func release() {
        guard !closed else { return }
        refCount -= 1
        guard refCount <= 0 else { return }
        closed = true
        let client = self.client
        let jumps = self.jumpClients
        Task.detached {
            try? await client.close()
            for jump in jumps.reversed() { try? await jump.close() }
        }
    }
}
