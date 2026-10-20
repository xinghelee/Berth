import XCTest
@testable import Berth

/// 半开连接的探测判定。这套时间算术错了,用户看到的仍然是一模一样的"敲键没反应",
/// 代码审查发现不了,所以逐条钉住。
final class LivenessGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func gate(silence: TimeInterval = 45, echo: TimeInterval = 3) -> LivenessGate {
        LivenessGate(silenceGap: silence, echoWait: echo)
    }

    /// 静默期内敲键属正常操作,一次都不该探
    func testKeystrokeWithinSilenceGapNeverProbes() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(44), outputAt: nil)
        XCTAssertFalse(gate.takeProbeDemand(outputAt: nil, at: later(50)))
    }

    func testKeystrokeAfterSilenceGapProbesOnceAfterEchoWindow() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(46), outputAt: nil)
        XCTAssertFalse(gate.takeProbeDemand(outputAt: nil, at: later(47)), "回显等待窗还没到")
        XCTAssertTrue(gate.takeProbeDemand(outputAt: nil, at: later(49)))
        XCTAssertFalse(gate.takeProbeDemand(outputAt: nil, at: later(60)), "需求取走即清,不能反复探")
    }

    /// 敲键后有回显 = 管道通着,这次怀疑作废且不能复活
    func testEchoInsideWindowCancelsSuspicion() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(60), outputAt: nil)
        XCTAssertFalse(gate.takeProbeDemand(outputAt: later(60.5), at: later(62)))
        XCTAssertFalse(gate.takeProbeDemand(outputAt: later(60.5), at: later(63.5)))
    }

    /// 等待窗口以第一次敲键为准 —— 否则一直敲就永远"还没等够",偏偏持续敲键最可能撞上死管道
    func testContinuousTypingDoesNotPushTheWindowBack() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(46), outputAt: nil)
        gate.noteKeystroke(at: later(48), outputAt: nil)
        XCTAssertTrue(gate.takeProbeDemand(outputAt: nil, at: later(49)))
    }

    /// 密码提示 / vim 这类零回显场景:探成功必须重新起算,否则每次敲键都开一条 exec 打服务器
    func testSuccessfulProbeRequiresAFreshSilenceGap() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(46), outputAt: nil)
        XCTAssertTrue(gate.takeProbeDemand(outputAt: nil, at: later(50)))

        gate.markAlive(at: later(50))
        gate.noteKeystroke(at: later(51), outputAt: nil)
        XCTAssertFalse(gate.takeProbeDemand(outputAt: nil, at: later(60)))

        gate.noteKeystroke(at: later(96), outputAt: nil)
        XCTAssertTrue(gate.takeProbeDemand(outputAt: nil, at: later(99)))
    }

    /// 远端输出同样算"有动静",即使探测从没确认过
    func testRemoteOutputCountsAsSignOfLife() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.noteKeystroke(at: later(100), outputAt: later(99))
        XCTAssertFalse(gate.takeProbeDemand(outputAt: later(99), at: later(104)))
    }

    /// 唤醒不等静默期:回来第一次按键之前就该把可疑连接探明白
    func testWakeArmsWithoutSilenceGap() {
        var gate = gate()
        gate.markAlive(at: t0)
        gate.armForWake(at: later(1))
        XCTAssertTrue(gate.takeProbeDemand(outputAt: nil, at: later(4.1)))
    }

    /// 没有基准时刻(刚建好还没连上)就不怀疑,免得自己把自己判死
    func testNothingConfirmedAliveNeverArms() {
        var gate = gate()
        gate.noteKeystroke(at: later(100), outputAt: nil)
        XCTAssertFalse(gate.takeProbeDemand(outputAt: nil, at: later(200)))
    }

    /// 用户从敲键到看见断线横幅的等待上界。调大常量前先在这里交代一句 ——
    /// 这条路径存在的意义就是"别让人敲了半天没反应"
    func testWorstCaseLatencyFromKeystrokeToVerdict() {
        let probing = Double(LivenessTiming.probeAttempts) * LivenessTiming.probeTimeout
            + Double(LivenessTiming.probeAttempts - 1) * LivenessTiming.probeRetryGap
        let worst = LivenessTiming.echoWait + LivenessTiming.poll + probing
        XCTAssertLessThanOrEqual(worst, 15, "判定太慢就等于没做")
    }
}
