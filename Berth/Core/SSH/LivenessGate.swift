import Foundation

/// 活性探测的节拍。全程事件驱动:没人用的时候一个包都不发,只在"用户可能正撞上死管道"时探一次。
/// 代价是没人碰的后台标签不会自己弹横幅,要等它按键或系统唤醒才判定 —— 换掉常态 keepalive 流量。
enum LivenessTiming {
    /// 距上次有任何动静超过这么久,之后的键入才开始怀疑
    static var silenceGap: TimeInterval { fastMode ? 1 : 45 }
    /// 武装后等这么久仍一个字节回显都没有,就去探测
    static var echoWait: TimeInterval { fastMode ? 0.3 : 3 }
    /// 探测循环节拍(纯本地 sleep,零流量)
    static var poll: TimeInterval { fastMode ? 0.2 : 2 }
    /// 单次探测等多久算"没回音"
    static var probeTimeout: TimeInterval { fastMode ? 0.5 : 3 }
    /// 两轮探测之间隔多久:单次没回音可能只是网络正好抖一下
    static var probeRetryGap: TimeInterval { fastMode ? 0.1 : 0.5 }
    /// 连续几轮没回音才认定连接失效
    static let probeAttempts = 2

    /// 系统唤醒后先缓这么久再探(无线网卡重新关联要时间)
    static var wakeGrace: TimeInterval { fastMode ? 0.2 : 10 }

    /// 集成测试(BERTH_LIVENESS_FAST=1)把节拍整体压到亚秒级 —— 否则每条测试都得真等
    /// 45s 静默期。Release 恒为 false,上面就是产品值。
    private static let fastMode: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BERTH_LIVENESS_FAST"] == "1"
        #else
        return false
        #endif
    }()
}

/// "什么时候该探一次"的纯判定。不碰网络、不读 `Date()`、不碰 SSH 状态,所以能离线钉住 ——
/// 这套判定错了,用户看到的还是"敲键没反应",光靠代码审查发现不了。
struct LivenessGate {
    var silenceGap: TimeInterval = LivenessTiming.silenceGap
    var echoWait: TimeInterval = LivenessTiming.echoWait

    /// 正在等回显的起点;nil = 当前没在怀疑
    private(set) var pendingEchoSince: Date?
    /// 上次"确认还活着"的时刻:刚连上、或探测拿到了回音
    private(set) var lastAliveAt: Date?

    /// 确认连接活着(连上时、以及探测有回音时调用):静默期重新起算,当前怀疑一并取消
    mutating func markAlive(at now: Date) {
        lastAliveAt = now
        pendingEchoSince = nil
    }

    /// 键入到达。`outputAt` 是最近一次收到远端输出的时刻。
    /// 已经在等就不重置 —— 否则持续敲键会把等待窗口一直往后推,永远等不到探测。
    mutating func noteKeystroke(at now: Date, outputAt: Date?) {
        guard pendingEchoSince == nil else { return }
        guard let seen = Self.lastSignOfLife(lastAliveAt: lastAliveAt, outputAt: outputAt) else { return }
        guard now.timeIntervalSince(seen) >= silenceGap else { return }
        pendingEchoSince = now
    }

    /// 探测循环每轮来取一次:现在该不该探。取走即清 —— 等待窗口里只要有任何输出,
    /// 说明管道通着,这次怀疑直接作废(命令本来就静默、远端在等输入都属正常)
    mutating func takeProbeDemand(outputAt: Date?, at now: Date) -> Bool {
        guard let since = pendingEchoSince else { return false }
        if let outputAt, outputAt >= since {
            pendingEchoSince = nil
            return false
        }
        guard now.timeIntervalSince(since) >= echoWait else { return false }
        pendingEchoSince = nil
        return true
    }

    /// 系统唤醒:不等静默期,直接武装一次(调用方负责先缓过 wakeGrace)
    mutating func armForWake(at now: Date) {
        pendingEchoSince = now
    }

    private static func lastSignOfLife(lastAliveAt: Date?, outputAt: Date?) -> Date? {
        [lastAliveAt, outputAt].compactMap { $0 }.max()
    }
}
