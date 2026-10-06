import AppKit
import Citadel
import Foundation
import NIOCore
import NIOSSH
import Observation
import SwiftTerm
import os

/// 单个 SSH 终端会话:状态机 idle → connecting → connected → disconnected(reason)。
/// UI 只订阅 `state`,不直接操作连接。TerminalView 由会话持有,
/// 断线后手动重连复用同一视图,scrollback 自然保留。
///
/// 注:规格中的 authenticating 状态并入 connecting(detail:) —— Citadel 的
/// connect 将 TCP/密钥交换/认证合并为单次调用,M2 若需要细分再挂通道事件。
@MainActor
@Observable
final class TerminalSession: Identifiable {

    enum State: Equatable {
        case idle
        case connecting(detail: String)
        case connected
        case disconnected(DisconnectReason)
    }

    enum DisconnectReason: Equatable {
        case userInitiated
        case remoteClosed
        case error(String)

        var message: String? {
            switch self {
            case .userInitiated: return nil
            case .remoteClosed: return String(localized: "连接已被服务器关闭")
            case .error(let text): return text
            }
        }
    }

    /// 拨号相关的错误(缺密钥文件 / Touch ID 未通过等)在 `SSHDialer.DialError`,
    /// 这里只留会话自身的错误。
    enum SessionError: LocalizedError {
        case notConnected
        case localShellFailed(String)
        case localShellExited(Int32?, String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return String(localized: "未连接,无法打开 SFTP。")
            case .localShellFailed(let path):
                return String(localized: "无法启动本地 Shell:\(path) 不存在或不可执行。可在「设置 → 终端」修改 Shell 路径。")
            case .localShellExited(let status, let path):
                let code = status.map { String($0) } ?? "?"
                return String(localized: "本地 Shell 启动后立即退出(退出码 \(code)):\(path)。请检查 shell 路径与其启动配置;可在「设置 → 终端」修改 Shell 路径。")
            }
        }
    }

    let id = UUID()
    let spec: HostSpec
    let terminalView: TerminalView

    private(set) var state: State = .idle
    /// 最近一次连接建立的时间(用于 inspector 显示连接时长)
    private(set) var connectedAt: Date?
    /// 端口转发运行态(inspector 展示,可单独开关)
    private(set) var forwardStates: [UUID: PortForwardService.ForwardState] = [:]
    /// 最近一条命令的退出码(需远端启用 OSC 133 shell 集成才有值)
    private(set) var lastExitCode: Int?
    /// 最近一条命令的耗时(OSC 133 C→D)
    private(set) var lastCommandDuration: TimeInterval?
    /// 当前是否正在执行命令(OSC 133 C..D 之间)
    private(set) var runningCommand = false
    @ObservationIgnored private var commandStartedAt: Date?
    /// 提示符位置标记(scroll-invariant 行号),⌘↑/⌘↓ 在命令间跳转
    @ObservationIgnored private var commandMarks: [Int] = []
    /// 每条命令的输出区间(SI 行号 [start, end) + 退出码),供"复制上条命令输出"
    @ObservationIgnored private var commandOutputs: [(start: Int, end: Int, code: Int?)] = []
    @ObservationIgnored private var pendingOutputStart: Int?
    /// 是否有可复制的命令输出(驱动菜单/状态栏可用态)
    private(set) var hasCommandOutput = false
    /// scroll-invariant 行号的已知边界(增量探测,避免每个提示符全量扫描)
    @ObservationIgnored private var siLower = 0
    @ObservationIgnored private var siUpper = 0
    @ObservationIgnored private var osc133 = OSC133Scanner()
    /// 远端当前工作目录(OSC 7 上报),重连后用于自动 cd 回去
    /// OSC 7 报上来的远端当前目录。参与 Observation:SFTP 面板要跟着它走
    private var lastRemoteDirectory: String?
    /// 本次连接需要恢复到的目录(重连时置)
    @ObservationIgnored private var restoreDirOnConnect: String?
    /// 等待用户决策的主机密钥确认(首次连接指纹 / 密钥变更警告)
    var hostKeyPrompt: HostKeyPrompt?
    /// 等待用户作答的 keyboard-interactive 质询(堡垒机 MFA 动态码等)
    var keyboardInteractivePrompt: KeyboardInteractivePrompt?
    @ObservationIgnored private var keyboardInteractiveContinuation: CheckedContinuation<[String]?, Never>?
    /// 自动重连:当前第几次尝试、是否已排定下一次
    private(set) var reconnectAttempt = 0
    private(set) var isAutoReconnectScheduled = false

    @ObservationIgnored private var client: SSHClient?
    /// 本会话当前所用连接的共享持有者(自建或借用);断开时 release,引用归零才真正关闭
    @ObservationIgnored private(set) var connection: SSHConnection?
    /// 待借用的连接(⌘T 复制 / 分屏 同主机时由 SessionManager 注入);一次性,消费后清空
    @ObservationIgnored private var willBorrow: SSHConnection?
    /// 本次运行是否走了借用路径(借用会话不自动重连,避免网络抖动时多会话各自新建 TCP 造成连接风暴)
    @ObservationIgnored private var isBorrower = false
    /// 本会话连上时在 KeyUseGrants 登记为「存活会话」了(断开时要注销)
    @ObservationIgnored private var holdsKeyUseGrant = false
    @ObservationIgnored private var forwardService: PortForwardService?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var stdinWriter: AsyncStream<StdinEvent>.Continuation?
    @ObservationIgnored private var userInitiatedDisconnect = false
    @ObservationIgnored private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// 只有成功连上过的会话才自动重连(认证失败/密钥被拒不重试)
    @ObservationIgnored private var everConnected = false
    /// 临时直连/自动化验收用:绕过 Keychain 的一次性凭据(不落任何持久化)
    @ObservationIgnored var transientPassword: String?
    @ObservationIgnored var transientPassphrase: String?
    /// 远端 shell 正常退出(exit)时回调,由 SessionManager 设为关闭该 pane
    @ObservationIgnored var onShellExit: (() -> Void)?
    /// 后台长任务通知:上次输出/上次通知时间
    @ObservationIgnored private var lastOutputAt: Date?
    @ObservationIgnored private var lastNotifiedAt: Date?
    /// 触发器匹配用的未完成行缓冲(按 \n 切分,剥离转义)
    @ObservationIgnored private var triggerLineBuffer = ""
    /// 本地 Shell(spec.isLocal)的 PTY 宿主。本地会话不使用任何 SSH 字段。
    @ObservationIgnored private var localPty: LocalPty?
    @ObservationIgnored private var localDirectoryRefreshScheduled = false
    /// 会话录制:输出剥离转义后追加到此文件
    @ObservationIgnored private var logHandle: FileHandle?
    /// 当前正在录制到的文件 URL(nil = 未录制)
    private(set) var logURL: URL?
    var isLogging: Bool { logURL != nil }

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    init(spec: HostSpec) {
        self.spec = spec
        let view = BerthTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isProductionHost = spec.isProduction
        self.terminalView = view
        terminalView.font = TerminalFontPrefs.resolved()
        ThemeStore.shared.apply(to: terminalView)
        CursorPrefs.apply(to: terminalView)
        terminalView.terminalDelegate = self
        view.focusSessionID = id
        view.isLocalSession = spec.isLocal
    }

    // MARK: - 连接复用

    /// 已连上时对外暴露本会话所用连接,供 SessionManager 让新会话(⌘T/分屏)复用。
    var liveConnection: SSHConnection? {
        guard case .connected = state else { return nil }
        return connection
    }

    /// 注入一条待复用的连接(一次性,仅对下一次 connect 生效)。同主机复用时避免新建 TCP。
    func prepareToBorrow(_ connection: SSHConnection) {
        willBorrow = connection
    }

    // MARK: - 生命周期

    /// 可重入:disconnected 后再次调用即手动重连
    func connect() {
        guard sessionTask == nil else { return }
        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
        // 重连(此前连过)且开启了恢复工作目录 → 连上后自动 cd 回上次目录
        let restoreEnabled = UserDefaults.standard.object(forKey: SettingsKeys.restoreWorkingDir) as? Bool ?? true
        restoreDirOnConnect = (everConnected && restoreEnabled) ? lastRemoteDirectory : nil
        state = spec.isLocal
            ? .connecting(detail: String(localized: "正在启动本地 Shell…"))
            : .connecting(detail: String(localized: "正在连接 \(spec.hostname):\(String(spec.port))…"))

        sessionTask = Task {
            var disconnectReason: DisconnectReason
            var shellExited = false
            let caughtError: Error?
            do {
                if spec.isLocal {
                    try await runLocalSession()
                } else {
                    do {
                        try await runSession()
                    } catch {
                        let blocked = LocalNetworkAccess.isLikelyBlocked(error, host: spec.hostname)
                        DebugLog.append("session failed host=\(spec.hostname):\(spec.port) userInitiated=\(userInitiatedDisconnect) localNetBlocked=\(blocked) raw=\(String(describing: error))")
                        // 局域网地址撞上 EHOSTUNREACH:多半是被 macOS 本地网络门禁挡了,
                        // 而 NIO 的 BSD socket 不会触发授权请求。这时候才去要授权,
                        // 拿到就重跑一次(TCP 都没建起来,重跑是干净的)
                        guard !userInitiatedDisconnect,
                              LocalNetworkAccess.isLikelyBlocked(error, host: spec.hostname),
                              await LocalNetworkAccess.requestAccess(host: spec.hostname, port: spec.port)
                        else { throw error }
                        try await runSession()
                    }
                }
                caughtError = nil
            } catch {
                caughtError = error
            }

            let disposition = SessionTerminationClassifier.classify(
                error: caughtError,
                everConnected: everConnected,
                userInitiated: userInitiatedDisconnect,
                isLocal: spec.isLocal,
                hostname: spec.hostname,
                port: spec.port,
                authMethod: spec.authMethod
            )

            if let error = caughtError {
                let category = SessionTerminationClassifier.categorize(error: error)
                DebugLog.append("session terminated host=\(spec.hostname):\(spec.port) disposition=\(disposition) category=\(category.rawValue) everConnected=\(everConnected)")
            } else {
                DebugLog.append("session terminated host=\(spec.hostname):\(spec.port) disposition=\(disposition) everConnected=\(everConnected)")
            }

            switch disposition {
            case .userInitiated:
                shellExited = false
                disconnectReason = .userInitiated
            case .cleanShellExit:
                shellExited = true
                disconnectReason = .remoteClosed
            case .transportFailure(let message):
                shellExited = false
                disconnectReason = .error(message)
            }
            state = .disconnected(disconnectReason)
            // 门禁授权从断开这一刻起算空闲(服务器重启后 15 分钟内重连不必再过 Touch ID)
            if holdsKeyUseGrant {
                holdsKeyUseGrant = false
                KeyUseGrants.shared.sessionDisconnected(spec)
            }
            // 会话结束时质询弹窗必须收掉:服务器可能在用户找手机输 MFA 码时超时断开
            //(LoginGraceTime),不收的话 sheet 悬在死管道上,提交毫无反应
            resolveKeyboardInteractivePrompt(answers: nil)
            resolveOutputExpectation(matched: false)
            stopPortForwards()
            stopLogging()
            stdinWriter?.finish()
            stdinWriter = nil
            let releasing = self.connection
            self.client = nil
            self.connection = nil
            // 本地进程兜底:正常路径已在 runLocalSession 内退出/终止,这里防泄漏
            if let pty = self.localPty {
                if pty.running { pty.terminate() }
                self.localPty = nil
            }
            sessionTask = nil
            // 引用归零才真正关闭底层连接/跳板;借用会话的 release 不会误关共享连接
            releasing?.release()
            // 远端 shell 正常退出(exit/logout → PTY EOF,干净关闭)→ 关掉该 pane,不重连;
            // 网络异常(.error)才保留断线横幅 + 自动重连
            if shellExited, everConnected {
                onShellExit?()
            } else {
                maybeScheduleReconnect(after: disconnectReason, error: caughtError)
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
        // 取消会话任务即结束 PTY 循环 → withPTY 只关自己的通道 → teardown 里 release 连接。
        // 不在此直接关 client:共享连接时会误伤其它复用会话(分屏/⌘T)。
        sessionTask?.cancel()
    }

    // MARK: - 自动重连(指数退避,保留 scrollback)

    func cancelAutoReconnect() {
        reconnectTask?.cancel()
        isAutoReconnectScheduled = false
    }

    private func maybeScheduleReconnect(after reason: DisconnectReason, error: Error?) {
        guard reason != .userInitiated, everConnected else { return }
        // 认证失败/主机密钥被拒不是网络抖动:重连只会拿同一份凭据反复撞墙
        //(每轮最多 4 次密码提交 × 8 轮),足以触发 fail2ban / AD 锁定 / PerSourcePenalties。
        // 留断线横幅让用户核对凭据后手动「立即重连」。
        if let error, SessionTerminationClassifier.categorize(error: error) == .authentication {
            DebugLog.append("auto-reconnect skipped host=\(spec.hostname):\(spec.port) reason=authentication")
            return
        }
        // 借用会话不自动重连:否则共享连接因网络抖动断开时,拥有者与所有分屏/复制会话会
        // 同时各自新建 TCP,形成连接风暴,反而触发服务器的频率惩罚。拥有者正常重连(仅 1 条),
        // 借用会话保持断线,由用户手动「立即重连」(此时走自建连接,单条,不成风暴)。
        guard !isBorrower else { return }
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.autoReconnect) as? Bool ?? true
        guard enabled, reconnectAttempt < 8 else { return }

        reconnectAttempt += 1
        isAutoReconnectScheduled = true
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard case .disconnected = self.state, self.isAutoReconnectScheduled else { return }
            self.isAutoReconnectScheduled = false
            self.connect()
        }
    }

    // MARK: - 主机密钥决策(known_hosts)

    /// UI 回填用户决定;未决时关闭弹窗按拒绝处理(幂等)
    func resolveHostKeyPrompt(accepted: Bool) {
        hostKeyPrompt = nil
        hostKeyContinuation?.resume(returning: accepted)
        hostKeyContinuation = nil
    }

    private func requestHostKeyDecision(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // 理论上不会并发出现两个决策请求;保守起见拒绝旧的
                self.hostKeyContinuation?.resume(returning: false)
                self.hostKeyContinuation = continuation
                self.hostKeyPrompt = prompt
                self.state = .connecting(detail: String(localized: "等待主机密钥确认…"))
            }
        }
    }

    // MARK: - keyboard-interactive 质询(堡垒机 MFA)

    /// UI 回填应答(与提示同数量、同顺序);nil = 用户取消,认证中止
    func resolveKeyboardInteractivePrompt(answers: [String]?) {
        keyboardInteractivePrompt = nil
        keyboardInteractiveContinuation?.resume(returning: answers)
        keyboardInteractiveContinuation = nil
    }

    /// 认证 delegate 的 UI 回调:挂出 sheet 并等用户作答(NIO 线程经 Task 跳到主线程)
    private func requestKeyboardInteractiveAnswers(_ challenge: KeyboardInteractiveAuthDelegate.Challenge) async -> [String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.keyboardInteractiveContinuation?.resume(returning: nil)
                self.keyboardInteractiveContinuation = continuation
                self.keyboardInteractivePrompt = KeyboardInteractivePrompt(challenge: challenge)
                self.state = .connecting(detail: String(localized: "等待交互式认证(MFA)…"))
            }
        }
    }

    /// 关闭标签页时调用:断开并放弃会话
    func shutdown() {
        disconnect()
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
    }

    /// 像用户粘贴一样写入终端。支持 bracketed paste 的 shell 不会把多行内容中的
    /// 换行当作立即执行，和 AI 代码卡片“写入、不自动回车”的承诺保持一致。
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        sendText(TerminalPasteEncoder.encode(text, bracketed: terminalView.getTerminal().bracketedPasteMode))
    }

    // MARK: - 命令位置标记(OSC 133 提示符 → ⌘↑/⌘↓ 跳转)

    /// 增量刷新 scroll-invariant 行号边界:上界随输出前进,下界随 scrollback 修剪上移
    private func refreshScrollInvariantBounds() {
        let terminal = terminalView.getTerminal()
        while terminal.getScrollInvariantLine(row: siUpper) != nil { siUpper += 1 }
        while siLower < siUpper, terminal.getScrollInvariantLine(row: siLower) == nil { siLower += 1 }
        while terminal.getScrollInvariantLine(row: siLower - 1) != nil { siLower -= 1 }
    }

    /// 记录一个提示符行(scroll-invariant),供命令间跳转
    // MARK: - 会话录制

    /// 开始把输出录制到文件(剥离颜色码,追加写)。写入头部一行元信息。
    @discardableResult
    func startLogging(to url: URL) -> Bool {
        stopLogging()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        handle.seekToEndOfFile()
        let header = "# Berth session log · \(spec.username)@\(spec.hostname):\(spec.port) · \(Date().formatted())\n"
        handle.write(Data(header.utf8))
        logHandle = handle
        logURL = url
        return true
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
        logURL = nil
    }

    private func appendToLog(_ text: String) {
        guard let logHandle else { return }
        logHandle.write(Data(ANSI.strip(text).utf8))
    }

    /// 触发器:把输出按行喂给引擎(引擎无启用项时几乎零成本)
    private func matchTriggers(bytes: [UInt8]) {
        guard TriggerEngine.shared.hasEnabledTriggers else { triggerLineBuffer = ""; return }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        triggerLineBuffer += text
        while let nl = triggerLineBuffer.firstIndex(of: "\n") {
            let line = String(triggerLineBuffer[..<nl])
            triggerLineBuffer.removeSubrange(triggerLineBuffer.startIndex...nl)
            TriggerEngine.shared.scan(line: line, hostLabel: spec.label)
        }
        // 缓冲过长(无换行的持续输出)截断,避免无限增长
        if triggerLineBuffer.count > 8192 {
            triggerLineBuffer = String(triggerLineBuffer.suffix(4096))
        }
    }

    /// 光标当前所在的 scroll-invariant 行号
    private func currentScrollInvariantRow() -> Int {
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        let viewportTop = max(siLower, siUpper - terminal.rows)
        return viewportTop + terminal.buffer.y
    }

    private func recordCommandMark() {
        let row = currentScrollInvariantRow()
        if commandMarks.last != row {
            commandMarks.append(row)
            if commandMarks.count > 1000 { commandMarks.removeFirst(commandMarks.count - 1000) }
        }
    }

    /// 命令结束(OSC 133 D):记录本条命令的输出区间
    private func recordCommandOutput(code: Int?) {
        guard let start = pendingOutputStart else { return }
        pendingOutputStart = nil
        let end = currentScrollInvariantRow()
        guard end > start else { return }
        commandOutputs.append((start: start, end: end, code: code))
        if commandOutputs.count > 200 { commandOutputs.removeFirst(commandOutputs.count - 200) }
        hasCommandOutput = true
    }

    /// 复制上一条命令的完整输出到剪贴板;返回是否成功
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        guard let last = commandOutputs.last else { return false }
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in last.start..<last.end {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        // 去掉尾部空行
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return false }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// ⌘↑:跳到当前视口上方最近的提示符
    func jumpToPreviousCommand() { jumpToCommand(direction: -1) }
    /// ⌘↓:跳到当前视口下方最近的提示符;没有更多则回到底部
    func jumpToNextCommand() { jumpToCommand(direction: 1) }

    private func jumpToCommand(direction: Int) {
        guard !commandMarks.isEmpty else { return }
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        // 修剪后已失效的旧标记一并清掉
        commandMarks.removeAll { $0 < siLower }
        let currentTop = siLower + terminal.buffer.yDisp
        let target = direction < 0
            ? commandMarks.last(where: { $0 < currentTop })
            : commandMarks.first(where: { $0 > currentTop })
        guard let target else {
            if direction > 0 { terminalView.scroll(toPosition: 1) }
            return
        }
        let maxScrollback = max((siUpper - siLower) - terminal.rows, 1)
        let position = Double(target - siLower) / Double(maxScrollback)
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }

    /// 连接后异步探测系统名并回写 Host(驱动侧栏系统徽章),失败静默。以 os-release 为准。
    private func captureServerOS() {
        Task { [weak self] in
            guard let self, let info = await self.fetchServerInfo() else { return }
            let os = info.os.isEmpty ? info.kernel : info.os
            SessionManager.shared.recordServerOS(hostID: self.spec.hostID, os: os)
        }
    }

    /// inspector 用:在同一连接上另开通道跑一条命令取服务器信息(不影响 PTY)。
    /// 命令保证 exit 0 且不写 stderr,避免 Citadel executeCommand 抛错。
    func fetchServerInfo() async -> ServerInfo? {
        guard let client else { return nil }
        let script = """
        printf 'HOSTNAME=%s\\n' "$(hostname 2>/dev/null)"
        printf 'KERNEL=%s\\n' "$(uname -sr 2>/dev/null)"
        printf 'OS=%s\\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
        printf 'UPTIME=%s\\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
        printf 'LOAD=%s\\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        printf 'CPUS=%s\\n' "$(nproc 2>/dev/null)"
        printf 'MEM=%s\\n' "$(free -m 2>/dev/null | awk '/Mem:/{print $3\"/\"$2\" MB\"}')"
        printf 'DISK=%s\\n' "$(df -h / 2>/dev/null | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}')"
        """
        do {
            let buffer = try await client.executeCommand("sh -c \(Self.shellQuote(script))")
            let text = String(buffer: buffer)
            return ServerInfo(parsing: text)
        } catch {
            return nil
        }
    }

    /// inspector 用:远端 Docker 状态(容器列表/不可用原因)。脚本保证 exit 0。
    func fetchDockerStatus() async -> DockerStatus? {
        guard let client else { return nil }
        do {
            let buffer = try await client.executeCommand(
                "sh -c \(Self.shellQuote(DockerStatus.collectionScript))",
                maxResponseSize: 1 << 20,
                mergeStreams: true
            )
            return DockerStatus(parsing: String(buffer: buffer))
        } catch {
            return nil
        }
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 连接后切换用户(issue #35)

    /// su/sudo 的密码提示:停在行尾、以冒号收尾等输入的那一行(`Password:`、`密码:`、
    /// `[sudo] password for x:`)。PAM 的「密码将过期」、MOTD 里的 password 字样后面都有换行,
    /// 只看最后一行就不会被它们骗到而把密码提前发出去
    nonisolated private static let passwordPromptPattern = try! NSRegularExpression(
        pattern: #"(?i)(password|passwort|passphrase|mot de passe|contraseña|密码|パスワード|пароль)[^\r\n]*:\s*$"#
    )

    /// 输出的最后一行是不是在等密码
    nonisolated static func looksLikePasswordPrompt(_ lastLine: String) -> Bool {
        let range = NSRange(location: 0, length: (lastLine as NSString).length)
        return passwordPromptPattern.firstMatch(in: lastLine, range: range) != nil
    }

    /// 连接后 `su - 用户`:等到密码提示再从 Keychain 取密码作答,等不到(10 秒)就不盲发,
    /// 密码从不进 startupCommands、不落盘。没存密码就只发 su,提示符留给用户手输。
    /// 分屏/复制标签开的新 shell 同样切换,否则那个 pane 会停在登录用户上。
    private func runSwitchUserIfNeeded() async {
        let target = spec.switchUser.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !spec.isLocal else { return }
        sendText("su - \(Self.shellQuote(target))\n")
        let prompted = await awaitOutput(untilLastLine: Self.looksLikePasswordPrompt, timeout: .seconds(10))
        guard prompted, !Task.isCancelled,
              let password = try? KeychainStore.read(account: KeychainStore.switchUserPasswordAccount(for: spec.hostID)),
              !password.isEmpty else { return }
        sendText(password + "\n")
        // 给 su 起新 shell 的时间,后面的 cd / 启动命令才落在切换后的 shell 里
        try? await Task.sleep(for: .milliseconds(800))
    }

    // MARK: - 输出期待(登录脚本用)

    private struct OutputExpectation {
        let predicate: (String) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }
    @ObservationIgnored private var outputExpectation: OutputExpectation?
    @ObservationIgnored private var expectationBuffer = ""

    /// 等到输出的最后一行(已去 ANSI,不含换行)满足条件;超时返回 false。
    /// 同一时刻只有一个等待者,新等待者会把旧的按未匹配结束。
    func awaitOutput(untilLastLine predicate: @escaping (String) -> Bool, timeout: Duration) async -> Bool {
        resolveOutputExpectation(matched: false)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolveOutputExpectation(matched: false)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            outputExpectation = OutputExpectation(predicate: predicate, continuation: continuation)
        }
    }

    private func resolveOutputExpectation(matched: Bool) {
        guard let pending = outputExpectation else { return }
        outputExpectation = nil
        expectationBuffer = ""
        pending.continuation.resume(returning: matched)
    }

    private func matchOutputExpectation(bytes: [UInt8]) {
        guard let pending = outputExpectation else { return }
        expectationBuffer += ANSI.strip(String(decoding: bytes, as: UTF8.self))
        // 只看最后一行:提示符停在行尾等输入才算数,前面带换行的行(命令回显、MOTD、PAM 提示)不算
        let lastLine = expectationBuffer
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last.map(String.init) ?? ""
        if pending.predicate(lastLine) {
            resolveOutputExpectation(matched: true)
        } else if expectationBuffer.count > 4096 {
            expectationBuffer = String(expectationBuffer.suffix(2048))
        }
    }

    /// 标签/溢出菜单的默认标题:临时本地 Shell 跟随当前目录(开多个才分得清,issue #41),
    /// 其余用主机显示名(本地 Shell 书签是用户起的名字)
    var tabTitle: String {
        if spec.isLocal, spec.hostID == HostSpec.localShellHostID {
            return LocalPath.shortName(lastRemoteDirectory ?? "~")
        }
        return PrivacyMode.shared.maskHost(in: spec.label, hostname: spec.hostname)
    }

    /// 远端当前工作目录(OSC 7 上报;未启用命令集成时为 nil)。AI 助手提示词用。
    /// 本地会话为 shell 进程的实际当前目录(内核查询)
    var currentRemoteDirectory: String? { lastRemoteDirectory }

    /// AI 助手用:同一连接上另开 exec 通道执行命令(不影响 PTY)。
    /// stderr 合并进输出,末尾标记捕获退出码,因此非零退出不会让 executeCommand 抛错。
    /// startingDirectory 非空时先 cd 过去再执行(用户终端所在目录,见 AIChatController)。
    /// 返回 nil = 会话未连接。5 分钟超时(防 tail -f 之类挂死)。
    func runAICommand(_ command: String, startingDirectory: String? = nil) async -> (output: String, exitCode: Int?)? {
        if spec.isLocal { return await runLocalAICommand(command, startingDirectory: startingDirectory) }
        guard let client else { return nil }
        let marker = "__BERTH_AI_EXIT__"
        let script = Self.aiCommandScript(command, startingDirectory: startingDirectory, marker: marker)
        let wrapped = "sh -c \(Self.shellQuote(script))"
        do {
            let buffer = try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
                group.addTask {
                    try await client.executeCommand(wrapped, maxResponseSize: 1 << 20, mergeStreams: true)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            var text = String(buffer: buffer)
            var exitCode: Int?
            if let range = text.range(of: "\n\(marker):", options: .backwards) {
                let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                exitCode = Int(tail)
                text = String(text[..<range.lowerBound])
            }
            return (text, exitCode)
        } catch is CancellationError {
            return (String(localized: "命令执行超时(5 分钟),可能在等待输入或长时间运行。"), nil)
        } catch {
            return (String(localized: "命令执行失败:\(error.localizedDescription)"), nil)
        }
    }

    /// AI exec 通道的包装脚本。命令跑在子 shell 里:命令自己 exit 非零时只结束子 shell,
    /// 包装脚本仍能打出标记行并以 0 退出 —— 否则 Citadel 会按非零 exit-status 抛错,
    /// 拿不到输出也拿不到退出码。cd 失败时直接退出子 shell,错误留在输出里让模型自行恢复。
    nonisolated static func aiCommandScript(_ command: String, startingDirectory: String?, marker: String) -> String {
        var body = ""
        if let directory = startingDirectory {
            body += "cd \(shellQuote(directory)) || exit\n"
        }
        body += command
        return "exec 2>&1\n(\n" + body + "\n)\nprintf '\\n\(marker):%s\\n' \"$?\""
    }

    /// AI 助手用:OSC 7 缺席时的兜底 —— exec 通道与 PTY 跑在同一条 SSH 连接上(M5 连接
    /// 复用),服务端是同一个 sshd 会话进程的子进程。从 $$ 向上找到 sshd,枚举其带 TTY 的
    /// 子进程(即各 PTY 的 shell),readlink /proc/<pid>/cwd 读出工作目录(无 /proc 的
    /// macOS/BSD 远端退回 lsof)。只读、零配置、不触碰用户终端;拿不到返回空数组;
    /// 同主机多标签共用连接时可能返回多个候选。10 秒超时。
    func probeRemoteWorkingDirectories() async -> [String] {
        guard let client else { return [] }
        let script = """
        p=$$
        sid=
        n=0
        while [ $n -lt 6 ]; do
          pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
          [ -n "$pp" ] && [ "$pp" -gt 1 ] 2>/dev/null || break
          case "$(ps -o comm= -p "$pp" 2>/dev/null)" in
            sshd*) sid=$pp; break ;;
          esac
          p=$pp
          n=$((n+1))
        done
        [ -n "$sid" ] || exit 0
        ps -A -o pid= -o ppid= -o tty= 2>/dev/null | while read cpid cppid ctty; do
          [ "$cppid" = "$sid" ] || continue
          case "$ctty" in ""|"?"|"??") continue ;; esac
          readlink "/proc/$cpid/cwd" 2>/dev/null && continue
          lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n "s/^n//p"
        done | sort -u
        exit 0
        """
        do {
            let buffer = try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
                group.addTask {
                    try await client.executeCommand("sh -c \(Self.shellQuote(script))", maxResponseSize: 1 << 16, mergeStreams: false)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            return Self.parseWorkingDirectoryProbe(String(buffer: buffer))
        } catch {
            return []
        }
    }

    /// 探测输出 → 绝对路径列表(去重保序,丢弃空行与非绝对路径的杂音)
    nonisolated static func parseWorkingDirectoryProbe(_ output: String) -> [String] {
        var seen = Set<String>()
        var directories: [String] = []
        for line in output.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/"), seen.insert(path).inserted else { continue }
            directories.append(path)
        }
        return directories
    }

    enum ShellHighlightResult { case installed, alreadyEnabled, notZsh(String), failed(String) }
    enum CommandIntegrationResult { case installed, alreadyEnabled, failed(String) }

    /// ⌘P 命令面板等外部入口请求检查器执行的增强动作(issue #32:入口藏得太深);
    /// 检查器打开后接手执行并清空,结果照常显示在「增强」区
    enum EnhancementRequest: Equatable { case shellHighlight, commandIntegration }
    var pendingEnhancement: EnhancementRequest?

    /// 启用命令集成(OSC 133):给 bash 和 zsh 的 rc 各追加一段钩子,在每次执行命令前后
    /// 发出 OSC 133 A/B/C/D 标记,客户端据此感知命令边界与退出码。幂等,重连后生效。
    func enableCommandIntegration() async -> CommandIntegrationResult {
        guard let client else { return .failed(String(localized: "未连接")) }
        // ⚠️ bash 钩子必须只在交互 shell 生效:Debian 系 bash 对 ssh 远程命令也会 source
        // .bashrc,无守卫的 DEBUG trap 会把 OSC 133 转义写进非交互会话的 stdout,直接
        // 打断 SFTP/scp 等子系统协议(表现为 "Received message too long")。
        // v2 标记 + 安装时自动清除旧版无守卫块,老主机重装即自愈。
        let script = #"""
        exec 2>&1
        OLD_MARK='# >>> berth command-integration >>>'
        OLD_END='# <<< berth command-integration <<<'
        MARK='# >>> berth shell-integration v2 >>>'
        END='# <<< berth shell-integration v2 <<<'
        BASH_HOOK='case $- in *i*)
        __berth_preexec() { printf "\033]133;C\007"; }
        __berth_precmd() { local e=$?; printf "\033]133;D;%s\007\033]133;A\007\033]7;file://%s%s\007" "$e" "${HOSTNAME:-}" "$PWD"; }
        if [ -n "$BASH_VERSION" ]; then
          case "$PROMPT_COMMAND" in *__berth_precmd*) : ;; *) PROMPT_COMMAND="__berth_precmd;${PROMPT_COMMAND}";; esac
          trap "__berth_preexec" DEBUG
        fi
        ;; esac'
        ZSH_HOOK='autoload -Uz add-zsh-hook 2>/dev/null
        __berth_preexec() { printf "\033]133;C\007"; }
        __berth_precmd() { printf "\033]133;D;%s\007\033]133;A\007\033]7;file://%s%s\007" "$?" "${HOST:-}" "$PWD"; }
        add-zsh-hook preexec __berth_preexec 2>/dev/null
        add-zsh-hook precmd __berth_precmd 2>/dev/null'
        added=0
        for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
          touch "$RC" 2>/dev/null || continue
          if grep -qF "$OLD_MARK" "$RC" 2>/dev/null; then
            sed -i "/^# >>> berth command-integration >>>/,/^# <<< berth command-integration <<</d" "$RC" 2>/dev/null
          fi
          if grep -qF "$MARK" "$RC" 2>/dev/null; then continue; fi
          case "$RC" in
            *.bashrc) printf '\n%s\n%s\n%s\n' "$MARK" "$BASH_HOOK" "$END" >> "$RC" && added=1 ;;
            *.zshrc)  printf '\n%s\n%s\n%s\n' "$MARK" "$ZSH_HOOK" "$END" >> "$RC" && added=1 ;;
          esac
        done
        [ "$added" = 1 ] && echo BERTH_DONE || echo BERTH_ALREADY
        """#
        do {
            let buffer = try await client.executeCommand("sh -c \(Self.shellQuote(script))")
            let out = String(buffer: buffer)
            if out.contains("BERTH_DONE") { return .installed }
            if out.contains("BERTH_ALREADY") { return .alreadyEnabled }
            return .failed(String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
        } catch {
            return .failed(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port, authMethod: spec.authMethod))
        }
    }

    enum SwitchZshResult { case done, needsRelogin, failed(String) }

    /// 一键把默认登录 shell 切到 zsh(装 zsh + chsh),再启用命令高亮。
    /// root 直接 chsh;非 root 走 sudo -n(装了免密 sudo 才行,否则提示手动)。
    func installAndSwitchToZsh() async -> SwitchZshResult {
        guard let client else { return .failed(String(localized: "未连接")) }
        let script = #"""
        exec 2>&1
        SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo -n"
        install() {
          if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
          elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y -q "$@"
          elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y -q "$@"
          elif command -v apk >/dev/null 2>&1; then $SUDO apk add --no-progress "$@"
          elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm "$@"
          elif command -v brew >/dev/null 2>&1; then brew install "$@"
          else return 1; fi
        }
        ZSH=$(command -v zsh || true)
        if [ -z "$ZSH" ]; then install zsh || { echo BERTH_NOPKG; exit 0; }; ZSH=$(command -v zsh || true); fi
        [ -z "$ZSH" ] && { echo BERTH_NOZSH; exit 0; }
        # 高亮包
        install zsh-syntax-highlighting >/dev/null 2>&1 || true
        # 切换默认 shell
        USER_NAME=$(id -un)
        if [ "$(id -u)" = "0" ]; then
          chsh -s "$ZSH" "$USER_NAME" 2>/dev/null || usermod -s "$ZSH" "$USER_NAME" 2>/dev/null || { echo BERTH_CHSH_FAIL; exit 0; }
        else
          $SUDO chsh -s "$ZSH" "$USER_NAME" 2>/dev/null || $SUDO usermod -s "$ZSH" "$USER_NAME" 2>/dev/null || { echo BERTH_CHSH_FAIL; exit 0; }
        fi
        # 写高亮 source 到 .zshrc(幂等)
        MARK='# >>> berth syntax-highlight >>>'
        RC="$HOME/.zshrc"; touch "$RC" 2>/dev/null || true
        HL=""
        for p in /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
          [ -f "$p" ] && { HL="$p"; break; }
        done
        if [ -n "$HL" ] && ! grep -q "$MARK" "$RC" 2>/dev/null; then
          printf '\n%s\n[ -f %s ] && source %s\n# <<< berth syntax-highlight <<<\n' "$MARK" "$HL" "$HL" >> "$RC"
        fi
        echo BERTH_SWITCHED
        """#
        do {
            let buffer = try await client.executeCommand("sh -c \(Self.shellQuote(script))")
            let out = String(buffer: buffer)
            if out.contains("BERTH_SWITCHED") { return .needsRelogin }
            if out.contains("BERTH_CHSH_FAIL") { return .failed(String(localized: "切换默认 shell 失败(可能需要密码或权限)")) }
            if out.contains("BERTH_NOPKG") { return .failed(String(localized: "未识别的包管理器,无法自动安装 zsh")) }
            if out.contains("BERTH_NOZSH") { return .failed(String(localized: "安装后仍未找到 zsh")) }
            return .failed(String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
        } catch {
            return .failed(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port, authMethod: spec.authMethod))
        }
    }

    /// 方案1:在远端启用命令高亮(zsh-syntax-highlighting)。仅对登录 shell 为 zsh 的用户生效
    /// —— 高亮脚本是 zsh 专有语法,写进 bash 的配置会报错。检测包管理器 → 安装 →
    /// 幂等追加 source 到 ~/.zshrc。全程一条命令且做了 `exec 2>&1`,不用 set -e(避免误伤),
    /// 不影响当前 PTY。
    func enableShellHighlight() async -> ShellHighlightResult {
        guard let client else { return .failed(String(localized: "未连接")) }
        let script = #"""
        exec 2>&1
        # 登录 shell 必须是 zsh,否则高亮脚本会在 bash/sh 里报语法错误
        LOGIN_SHELL=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
        [ -z "$LOGIN_SHELL" ] && LOGIN_SHELL="$SHELL"
        case "$LOGIN_SHELL" in
          */zsh) : ;;
          *) echo "BERTH_NOTZSH:$LOGIN_SHELL"; exit 0 ;;
        esac
        MARK='# >>> berth syntax-highlight >>>'
        RC="$HOME/.zshrc"
        touch "$RC" 2>/dev/null || true
        if grep -q "$MARK" "$RC" 2>/dev/null; then echo BERTH_ALREADY; exit 0; fi
        find_zsh_hl() {
          for p in /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
            [ -f "$p" ] && { echo "$p"; return 0; }
          done
          return 1
        }
        HL=$(find_zsh_hl || true)
        if [ -z "$HL" ]; then
          SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo -n"
          if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh-syntax-highlighting
          elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y -q zsh-syntax-highlighting
          elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y -q zsh-syntax-highlighting
          elif command -v apk >/dev/null 2>&1; then $SUDO apk add --no-progress zsh-syntax-highlighting
          elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm zsh-syntax-highlighting
          elif command -v brew >/dev/null 2>&1; then brew install zsh-syntax-highlighting
          else echo BERTH_NOPKG; exit 0
          fi
          HL=$(find_zsh_hl || true)
        fi
        [ -z "$HL" ] && { echo BERTH_NOTFOUND; exit 0; }
        printf '\n%s\n[ -f %s ] && source %s\n# <<< berth syntax-highlight <<<\n' "$MARK" "$HL" "$HL" >> "$RC"
        echo BERTH_DONE
        """#
        do {
            let buffer = try await client.executeCommand("sh -c \(Self.shellQuote(script))")
            let out = String(buffer: buffer)
            if out.contains("BERTH_ALREADY") { return .alreadyEnabled }
            if out.contains("BERTH_DONE") { return .installed }
            if let range = out.range(of: "BERTH_NOTZSH:") {
                let shell = out[range.upperBound...].prefix { !$0.isNewline }
                return .notZsh(shell.isEmpty ? String(localized: "非 zsh") : String(shell))
            }
            if out.contains("BERTH_NOPKG") { return .failed(String(localized: "未识别的包管理器,请手动安装 zsh-syntax-highlighting")) }
            if out.contains("BERTH_NOTFOUND") { return .failed(String(localized: "安装后未找到高亮脚本(可能需要 sudo 权限)")) }
            return .failed(String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
        } catch {
            return .failed(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port, authMethod: spec.authMethod))
        }
    }

    /// 后台时长任务完成提醒:app 不在前台,且本次输出距上次输出静默 ≥10s → 视为长命令出结果
    private func noteOutputForNotification() {
        let now = Date()
        defer { lastOutputAt = now }
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.notifyLongCommand) as? Bool ?? true
        guard enabled, !NSApp.isActive, case .connected = state else { return }
        guard let last = lastOutputAt, now.timeIntervalSince(last) >= 10 else { return }
        // 同会话 30s 内不重复打扰
        if let lastNotified = lastNotifiedAt, now.timeIntervalSince(lastNotified) < 30 { return }
        lastNotifiedAt = now
        NotificationService.post(title: spec.label, body: String(localized: "长任务有新输出(静默 \(Int(now.timeIntervalSince(last))) 秒后)"))
    }

    func focusTerminal() {
        if let view = terminalView as? BerthTerminalView {
            view.requestFocus()
        } else {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    /// 在当前连接上开一个 SFTP 子通道(与 PTY 并存,复用同一 SSHClient)
    func openSFTP() async throws -> SFTPClient {
        guard let client else { throw SessionError.notConnected }
        return try await client.openSFTP()
    }

    // MARK: - 端口转发

    private func startPortForwards() {
        guard !spec.forwards.isEmpty else { return }
        for forward in spec.forwards { forwardStates[forward.id] = .starting }
        ensureForwardService()?.start(spec.forwards)
    }

    private func stopPortForwards() {
        forwardService?.stopAll()
        forwardService = nil
        forwardStates = [:]
        runtimeForwards = []
    }

    /// 惰性创建转发 service(主机没配转发时也能临时加)。未连接返回 nil。
    private func ensureForwardService() -> PortForwardService? {
        if let forwardService { return forwardService }
        guard let client else { return nil }
        let service = PortForwardService(client: client) { [weak self] id, state in
            Task { @MainActor in self?.forwardStates[id] = state }
        }
        forwardService = service
        return service
    }

    // MARK: - 即时(临时)端口转发

    /// 运行中临时新增的转发(不落库),供 UI 展示与单独停止
    private(set) var runtimeForwards: [PortForwardSpec] = []

    /// 会话运行中临时加一条转发;需已连接。成功返回该转发 id。
    @discardableResult
    func addRuntimeForward(_ spec: PortForwardSpec) -> Bool {
        guard case .connected = state, let service = ensureForwardService() else { return false }
        runtimeForwards.append(spec)
        forwardStates[spec.id] = .starting
        service.start([spec])
        return true
    }

    /// 停止并移除一条临时转发
    func removeRuntimeForward(_ id: UUID) {
        forwardService?.stop(id)
        runtimeForwards.removeAll { $0.id == id }
        forwardStates[id] = nil
    }

    // MARK: - 连接实现

    /// 交互式拨号器:进度回写 state,主机密钥/MFA 弹窗问用户,用密钥前过 Touch ID。
    /// (拨号逻辑本身与仪表盘监控共用,见 SSHDialer)
    private func makeDialer() -> SSHDialer {
        SSHDialer(
            spec: spec,
            transientPassword: transientPassword,
            transientPassphrase: transientPassphrase,
            onProgress: { [weak self] detail in
                self?.state = .connecting(detail: detail)
            },
            hostKeyDecision: { [weak self] prompt in
                guard let self else { return false }
                return await self.requestHostKeyDecision(prompt)
            },
            keyboardInteractive: { [weak self] challenge in
                await self?.requestKeyboardInteractiveAnswers(challenge)
            },
            keyGate: { [weak self] in
                guard let self else { return }
                // issue #29:同一主机本次运行内过一次门禁即可,重连/新建独立连接不再弹;
                // 空闲 15 分钟或换了认证材料才重新验证(KeyUseGrants)
                try await KeyUseGrants.shared.authorize(self.spec) {
                    try await SSHDialer.touchIDGate(
                        reason: String(localized: "使用私钥连接 \(self.spec.label)"),
                        onProgress: { detail in self.state = .connecting(detail: detail) }
                    )
                }
            }
        )
    }

    private func runSession() async throws {
        let client: SSHClient
        let connection: SSHConnection
        if let borrow = willBorrow, borrow.isAlive {
            // 借用已建立的连接:跳过 TCP/密钥交换/认证/主机密钥/Touch ID,直接在其上开 PTY 通道
            isBorrower = true
            willBorrow = nil
            borrow.retain()
            connection = borrow
            client = borrow.client
            state = .connecting(detail: String(localized: "复用现有连接,正在打开终端通道…"))
        } else {
            isBorrower = false
            willBorrow = nil
            let outcome = try await makeDialer().dial()
            // 跳板链所有权转入 SSHConnection,由引用计数统一管理关闭
            connection = SSHConnection(client: outcome.client, jumpClients: outcome.jumpClients)
            connection.retain()
            client = outcome.client
            state = .connecting(detail: String(localized: "认证成功,正在打开终端通道…"))
        }
        self.client = client
        self.connection = connection

        let term = terminalView.getTerminal()
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: term.cols,
            terminalRowHeight: term.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
        // 不假设服务器安装了 C.UTF-8 (CentOS 7 等旧系统可能没有)。
        // 仅在缺少 UTF-8 字符环境时补 LC_CTYPE,保留 LANG/LC_ALL 和其他类别。
        let localeCommand = "sh -c \(Self.shellQuote(RemoteLocale.probeScript))"
        let characterLocale = await RemoteLocale.detect {
            let output = try await client.executeCommand(localeCommand, maxResponseSize: 64 * 1024)
            return String(buffer: output)
        }
        try Task.checkCancellation()
        let localeEnvironment: [SSHChannelRequestEvent.EnvironmentRequest] = characterLocale.map {
            [.init(wantReply: false, name: "LC_CTYPE", value: $0)]
        } ?? []

        try await client.withPTY(ptyRequest, environment: localeEnvironment) { inbound, outbound in
            let (stream, continuation) = AsyncStream.makeStream(of: StdinEvent.self)
            await MainActor.run {
                self.stdinWriter = continuation
                self.syncTerminalSize()
                self.state = .connected
                self.holdsKeyUseGrant = KeyUseGrants.shared.sessionConnected(self.spec)
                self.connectedAt = Date()
                self.everConnected = true
                self.reconnectAttempt = 0
                self.focusTerminal()
                // 端口转发绑在连接层:仅拥有者建立,借用会话复用同一连接不重复绑定
                if !self.isBorrower {
                    self.startPortForwards()
                    self.captureServerOS()
                }
            }

            // 单一消费者串行写入,保证按键与 resize 的顺序
            let stdinPump = Task {
                for await event in stream {
                    switch event {
                    case .bytes(let bytes):
                        try await outbound.write(ByteBuffer(bytes: bytes))
                    case .resize(let cols, let rows):
                        try await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                    }
                }
            }
            defer { stdinPump.cancel() }

            // 登录后的自动动作(su 切换用户 → 恢复工作目录 → 启动命令)要边看输出边发,
            // 所以和下面的读循环并行跑;都经 stdin 流写入,与按键同一条队列
            let restoreDir = restoreDirOnConnect
            restoreDirOnConnect = nil
            let loginActions = Task { [weak self] in
                guard let self else { return }
                // 稍等 shell 提示符就绪再发,避免被吞
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await self.runSwitchUserIfNeeded()
                // 重连恢复工作目录:先 cd 回上次目录
                if let dir = restoreDir, !dir.isEmpty {
                    let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    self.sendText(" cd " + quoted + "\n")
                }
                // 连接后自动执行命令(逐行发送,自动补回车)。分屏借用会话不重复执行。
                let startup = self.spec.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines)
                if !self.isBorrower, !startup.isEmpty {
                    for line in startup.split(whereSeparator: \.isNewline) {
                        let cmd = line.trimmingCharacters(in: .whitespaces)
                        guard !cmd.isEmpty, !Task.isCancelled else { continue }
                        self.sendText(cmd + "\n")
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                }
            }
            defer { loginActions.cancel() }

            for try await chunk in inbound {
                let buffer: ByteBuffer
                switch chunk {
                case .stdout(let b), .stderr(let b):
                    buffer = b
                }
                let bytes = Array(buffer.readableBytesView)
                await MainActor.run {
                    self.ingest(bytes: bytes)
                }
            }
        }
    }

    /// 输出统一入口(SSH 通道与本地 PTY 共用):OSC 133 扫描 → 喂终端 → 触发器/录制/通知
    private func ingest(bytes: [UInt8]) {
        noteOutputForNotification()
        // OSC 133 命令边界/退出码。必须先把标记之前的字节喂进终端,
        // 再读光标行,才能拿到与标记对齐的 scroll-invariant 位置(否则记到旧位置)。
        var fed = 0
        for (event, offset) in osc133.scan(bytes[...]) {
            if offset > fed {
                terminalView.feed(byteArray: bytes[fed..<offset])
                fed = offset
            }
            switch event {
            case .commandStart:
                runningCommand = true
            case .outputStart:
                runningCommand = true
                commandStartedAt = Date()
                pendingOutputStart = currentScrollInvariantRow()
            case .commandEnd(let code):
                runningCommand = false
                lastExitCode = code
                lastCommandDuration = commandStartedAt.map { Date().timeIntervalSince($0) }
                commandStartedAt = nil
                recordCommandOutput(code: code)
            case .promptStart:
                recordCommandMark()
            }
        }
        if fed < bytes.count {
            terminalView.feed(byteArray: bytes[fed...])
        }
        matchTriggers(bytes: bytes)
        matchOutputExpectation(bytes: bytes)
        scheduleLocalDirectoryRefresh()
        if logHandle != nil, let text = String(bytes: bytes, encoding: .utf8) {
            appendToLog(text)
        }
    }

    // MARK: - 本地 Shell(spec.isLocal)

    /// 本地会话:posix_spawn 起本机 shell 挂到同一个 TerminalView(不用 forkpty ——
    /// 多线程进程里 fork 会死锁,启动恢复标签时必现「有回显没提示符」)。
    /// 生命周期对齐 SSH 路径:正常退出(exit)→ 干净返回 → onShellExit 关 pane;
    /// 任务取消(⌘W/断开)→ SIGTERM,退出事件经 monitor 正常送达。
    private func runLocalSession() async throws {
        let shell = LocalShell.resolvedShellPath()
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw SessionError.localShellFailed(shell)
        }
        let term = terminalView.getTerminal()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("SHELL=\(shell)")
        env.append("TERM_PROGRAM=Berth")
        let directory = Self.localStartDirectory(spec.localDirectory)
        let pty: LocalPty
        do {
            // 按 Terminal.app 惯例 argv[0] 带 "-" 前缀,让 shell 走登录初始化(zprofile 等)
            pty = try LocalPty(
                executable: shell,
                execName: "-" + (shell as NSString).lastPathComponent,
                environment: env,
                directory: directory,
                cols: term.cols,
                rows: term.rows
            )
        } catch {
            DebugLog.append("local shell spawn failed shell=\(shell) error=\(error)")
            throw SessionError.localShellFailed(shell)
        }
        localPty = pty
        DebugLog.append("local shell spawned pid=\(pty.pid) shell=\(shell)")
        lastRemoteDirectory = directory
        pty.onData = { [weak self] bytes in
            self?.ingest(bytes: bytes)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: StdinEvent.self)
        stdinWriter = continuation
        syncTerminalSize()
        state = .connected
        connectedAt = Date()
        everConnected = true
        reconnectAttempt = 0
        focusTerminal()

        // 键入/resize 直接落到本地 PTY(与 SSH 路径共用 StdinEvent 流,广播/片段无感)
        let stdinPump = Task {
            for await event in stream {
                switch event {
                case .bytes(let bytes):
                    pty.send(bytes)
                case .resize(let cols, let rows):
                    pty.resize(cols: cols, rows: rows)
                }
            }
        }
        defer { stdinPump.cancel() }

        // 书签的启动命令(分屏/⌘T 派生的会话 spec 已清空,不重复执行)
        let startup = spec.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines)
        let startupTask = Task { [weak self] in
            guard !startup.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            for line in startup.split(whereSeparator: \.isNewline) {
                let cmd = line.trimmingCharacters(in: .whitespaces)
                guard !cmd.isEmpty, !Task.isCancelled else { continue }
                self?.sendText(cmd + "\n")
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { startupTask.cancel() }

        // 等待子进程退出;任务取消(用户断开/关 pane)时 SIGTERM,由退出监视器收尾
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pty.whenExited { cont.resume() }
            }
        } onCancel: {
            pty.terminate()
        }
        try Task.checkCancellation()
        // 启动即退(2 秒内且非正常退出):按错误处理并报出退出码,而不是无声关掉
        // pane ——「画面闪一下就没了」无法诊断(issue #10)。退出码 0(用户秒敲
        // exit / 脚本正常结束)仍走正常关 pane。
        let uptime = Date().timeIntervalSince(pty.spawnedAt)
        if uptime < 2, (pty.exitStatus ?? -1) != 0 {
            DebugLog.append("local shell exited immediately uptime=\(uptime) status=\(String(describing: pty.exitStatus))")
            throw SessionError.localShellExited(pty.exitStatus, shell)
        }
    }

    /// 书签起始目录:展开 ~,不存在/不是目录则回落家目录(目录被删/换了机器同步过来)
    static func localStartDirectory(_ configured: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return home }
        let expanded = LocalPath.expand(trimmed)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            DebugLog.append("local shell start dir missing, falling back to home")
            return home
        }
        return expanded
    }

    /// 本地 shell 进程的当前目录(issue #41):macOS 自带 zsh 不发 OSC 7
    /// (只对 Apple_Terminal 发),标签标题直接问内核。输出后合并成一次查询
    private func scheduleLocalDirectoryRefresh() {
        guard spec.isLocal, !localDirectoryRefreshScheduled, localPty != nil else { return }
        localDirectoryRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.localDirectoryRefreshScheduled = false
            guard let pid = self.localPty?.pid, pid > 0,
                  let cwd = Self.processWorkingDirectory(pid),
                  cwd != self.lastRemoteDirectory else { return }
            self.lastRemoteDirectory = cwd
        }
    }

    nonisolated static func processWorkingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// AI 助手用(本地会话):独立子进程执行命令,不触碰用户的交互 shell。
    /// 包装脚本与 SSH 版共用(stderr 合并、标记行取退出码);5 分钟超时。
    private func runLocalAICommand(_ command: String, startingDirectory: String?) async -> (output: String, exitCode: Int?)? {
        guard case .connected = state else { return nil }
        let marker = "__BERTH_AI_EXIT__"
        let script = Self.aiCommandScript(command, startingDirectory: startingDirectory, marker: marker)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // 后台队列边跑边收,避免子进程写满 64KB 管道缓冲后卡死
        let collected = LockedDataBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }

        let watchdog = Task.detached { [weak process] in
            try? await Task.sleep(for: .seconds(300))
            process?.terminate()
        }
        defer { watchdog.cancel() }

        let launched: Bool = await withCheckedContinuation { cont in
            process.terminationHandler = { _ in cont.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(returning: false)
            }
        }
        guard launched else {
            return (String(localized: "命令执行失败:无法启动 /bin/sh"), nil)
        }
        // 给 readabilityHandler 一拍把尾部字节收完
        try? await Task.sleep(for: .milliseconds(80))
        pipe.fileHandleForReading.readabilityHandler = nil

        var text = String(data: collected.snapshot, encoding: .utf8) ?? ""
        var exitCode: Int?
        if let range = text.range(of: "\n\(marker):", options: .backwards) {
            let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            exitCode = Int(tail)
            text = String(text[..<range.lowerBound])
        }
        return (text, exitCode)
    }

}

// MARK: - TerminalViewDelegate(AppKit 主线程回调)

extension TerminalSession: TerminalViewDelegate {

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            _ = stdinWriter?.yield(.bytes(bytes))
            // 广播输入:把本 pane 的键入同步到同标签其它 pane
            SessionManager.shared.broadcastInput(from: id, bytes: bytes)
        }
    }

    /// 广播/自动化用:直接把字节写入本会话 stdin(不经过 terminalView)
    func sendRawInput(_ bytes: [UInt8]) {
        _ = stdinWriter?.yield(.bytes(bytes))
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            _ = stdinWriter?.yield(.resize(cols: newCols, rows: newRows))
        }
    }

    /// 建好 stdin 流后按视图当前尺寸补一次 resize。
    /// 连接/spawn 与 SwiftUI 布局各走各的时序,布局落在 stdinWriter 就位之前时
    /// sizeChanged 会被丢掉(那时 writer 还是 nil),远端/本地 PTY 就停在开channel
    /// 时的旧尺寸上,表现为折行列数与画面对不上。
    private func syncTerminalSize() {
        let term = terminalView.getTerminal()
        guard term.cols > 0, term.rows > 0 else { return }
        _ = stdinWriter?.yield(.resize(cols: term.cols, rows: term.rows))
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            // 形如 file://host/path 或直接路径;取路径部分。
            // URL.path 已做过百分号解码,再解一次会把目录名里字面的 %XX 吃掉
            //(/data/100%41 变 /data/100A)。
            guard let dir = directory else { return }
            let path: String?
            if let url = URL(string: dir), url.scheme == "file" {
                path = url.path
            } else if dir.hasPrefix("/") {
                path = dir
            } else {
                path = nil
            }
            // 多数 shell 每个提示符都发一遍 OSC 7,同值写入会白白触发 Observation
            //(SFTP 面板整个 body 重算一轮)
            if let path, path != lastRemoteDirectory {
                lastRemoteDirectory = path
            }
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated {
            let enabled = UserDefaults.standard.object(forKey: SettingsKeys.notifyLongCommand) as? Bool ?? true
            guard enabled, !NSApp.isActive else { return }
            if let lastNotified = lastNotifiedAt, Date().timeIntervalSince(lastNotified) < 30 { return }
            lastNotifiedAt = Date()
            NotificationService.post(title: spec.label, body: String(localized: "终端响铃"))
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// ⌘点击链接:http/https/ftp/mailto/file 用默认应用打开;补全裸域名的协议头
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        // 裸域名(www. 开头或含点无协议)补 https://
        if !s.contains("://"), !s.hasPrefix("mailto:") {
            if s.hasPrefix("www.") || (s.contains(".") && !s.hasPrefix("/")) {
                s = "https://" + s
            }
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "mailto", "file"].contains(scheme) else { return }
        MainActor.assumeIsolated { NSWorkspace.shared.open(url) }
    }
}

/// 跨队列收集子进程输出(Pipe 的 readabilityHandler 在后台队列回调)
private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
