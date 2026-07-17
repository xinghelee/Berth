import AppKit
import Citadel
import Crypto
import Foundation
import LocalAuthentication
import NIOCore
import NIOSSH
import Observation
import SwiftTerm

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

    enum SessionError: LocalizedError {
        case unsupportedKey
        case missingStoredKey
        case authenticationGateFailed
        case notConnected

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return String(localized: "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。")
            case .missingStoredKey:
                return String(localized: "找不到该主机引用的密钥,请在「密钥」页检查或重新选择。")
            case .authenticationGateFailed:
                return String(localized: "身份验证未通过,已取消连接。可在设置中关闭「使用密钥前要求 Touch ID」。")
            case .notConnected:
                return String(localized: "未连接,无法打开 SFTP。")
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
    @ObservationIgnored private var lastRemoteDirectory: String?
    /// 本次连接需要恢复到的目录(重连时置)
    @ObservationIgnored private var restoreDirOnConnect: String?
    /// 等待用户决策的主机密钥确认(首次连接指纹 / 密钥变更警告)
    var hostKeyPrompt: HostKeyPrompt?
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
    /// 跳板链上的中间 client,必须保活以维持隧道;所有权在建立后转入 SSHConnection
    @ObservationIgnored private var jumpClients: [SSHClient] = []
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

    private enum StdinEvent {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    init(spec: HostSpec) {
        self.spec = spec
        let fontSize = CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
        let view = BerthTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isProductionHost = spec.isProduction
        self.terminalView = view
        terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        ThemeStore.shared.apply(to: terminalView)
        CursorPrefs.apply(to: terminalView)
        terminalView.terminalDelegate = self
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
        state = .connecting(detail: String(localized: "正在连接 \(spec.hostname):\(String(spec.port))…"))

        sessionTask = Task {
            var disconnectReason: DisconnectReason
            var shellExited = false
            do {
                try await runSession()
                // 干净返回(收到 exit-status 0 / 干净 EOF)= shell 正常退出
                shellExited = !userInitiatedDisconnect
                disconnectReason = userInitiatedDisconnect ? .userInitiated : .remoteClosed
            } catch is CancellationError {
                disconnectReason = .userInitiated
            } catch {
                if userInitiatedDisconnect {
                    disconnectReason = .userInitiated
                } else if everConnected, Self.isCleanShellExit(error) {
                    // 连接阶段的失败(认证被拒等)不可能是 shell 退出,必须走 .error 保留详情
                    // 抛出的其实是通道 EOF/关闭(exit 与连接关闭竞速),视为 shell 退出
                    shellExited = true
                    disconnectReason = .remoteClosed
                } else {
                    disconnectReason = .error(SSHErrorMapper.friendlyMessage(for: error, hostname: spec.hostname, port: spec.port, authMethod: spec.authMethod))
                }
            }
            state = .disconnected(disconnectReason)
            stopPortForwards()
            stdinWriter?.finish()
            stdinWriter = nil
            let releasing = self.connection
            // 连接建立中途失败(如跳板链某一跳出错)时,已连上的跳板还没转入 SSHConnection,
            // 留在 jumpClients 里,须在此关闭,否则泄漏半开连接(还会占满服务器 MaxStartups)
            let orphanedJumps = self.jumpClients
            self.client = nil
            self.connection = nil
            self.jumpClients = []
            sessionTask = nil
            if !orphanedJumps.isEmpty {
                Task.detached {
                    for jump in orphanedJumps.reversed() { try? await jump.close() }
                }
            }
            // 引用归零才真正关闭底层连接/跳板;借用会话的 release 不会误关共享连接
            releasing?.release()
            // 远端 shell 正常退出(exit/logout → PTY EOF,干净关闭)→ 关掉该 pane,不重连;
            // 网络异常(.error)才保留断线横幅 + 自动重连
            if shellExited, everConnected {
                onShellExit?()
            } else {
                maybeScheduleReconnect(after: disconnectReason)
            }
        }
    }

    /// 判断断开是否为 shell 正常退出(通道 EOF/关闭)而非网络异常(reset/timeout/refused…)
    private static func isCleanShellExit(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        // 明确的网络异常关键词 → 不是干净退出,应保留横幅并重连
        let networky = ["reset", "refused", "timed out", "timeout", "unreachable",
                        "no route", "broken pipe", "not connected", "connection closed by",
                        "handshake", "posix"]
        if networky.contains(where: { s.contains($0) }) { return false }
        // 其余(通道 EOF/关闭/退出码/未知)一律按 shell 退出处理 —— 已连上时通道关闭
        // 绝大多数就是用户敲了 exit;真正的网络掉线基本都会命中上面的关键词
        return true
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

    private func maybeScheduleReconnect(after reason: DisconnectReason) {
        guard reason != .userInitiated, everConnected else { return }
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

    /// 关闭标签页时调用:断开并放弃会话
    func shutdown() {
        disconnect()
    }

    func sendText(_ text: String) {
        stdinWriter?.yield(.bytes(Array(text.utf8)))
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
            let buffer = try await client.executeCommand("sh -c \(shellQuote(script))")
            let text = String(buffer: buffer)
            return ServerInfo(parsing: text)
        } catch {
            return nil
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum ShellHighlightResult { case installed, alreadyEnabled, notZsh(String), failed(String) }
    enum CommandIntegrationResult { case installed, alreadyEnabled, failed(String) }

    /// 启用命令集成(OSC 133):给 bash 和 zsh 的 rc 各追加一段钩子,在每次执行命令前后
    /// 发出 OSC 133 A/B/C/D 标记,客户端据此感知命令边界与退出码。幂等,重连后生效。
    func enableCommandIntegration() async -> CommandIntegrationResult {
        guard let client else { return .failed("未连接") }
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
            let buffer = try await client.executeCommand("sh -c \(shellQuote(script))")
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
        guard let client else { return .failed("未连接") }
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
            let buffer = try await client.executeCommand("sh -c \(shellQuote(script))")
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
        guard let client else { return .failed("未连接") }
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
            let buffer = try await client.executeCommand("sh -c \(shellQuote(script))")
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
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// 在当前连接上开一个 SFTP 子通道(与 PTY 并存,复用同一 SSHClient)
    func openSFTP() async throws -> SFTPClient {
        guard let client else { throw SessionError.notConnected }
        return try await client.openSFTP()
    }

    // MARK: - 端口转发

    private func startPortForwards() {
        guard let client, !spec.forwards.isEmpty else { return }
        forwardStates = Dictionary(uniqueKeysWithValues: spec.forwards.map { ($0.id, .starting) })
        let service = PortForwardService(client: client) { [weak self] id, state in
            Task { @MainActor in self?.forwardStates[id] = state }
        }
        forwardService = service
        service.start(spec.forwards)
    }

    private func stopPortForwards() {
        forwardService?.stopAll()
        forwardService = nil
        forwardStates = [:]
    }

    // MARK: - 连接实现

    /// 建立到目标主机的 SSHClient:无跳板则直连;有跳板则连最外层跳板后逐跳 jump。
    /// 中间跳板的 client 必须保活(隧道依赖它),存入 jumpClients。
    private func establishClient() async throws -> SSHClient {
        guard !spec.jump.isEmpty else {
            return try await connectEntry(to: spec, useTransient: true)
        }

        // 连最外层跳板
        let first = spec.jump[0]
        state = .connecting(detail: String(localized: "正在连接跳板机 \(first.hostname):\(String(first.port))…"))
        var current = try await connectEntry(to: first, useTransient: false)
        jumpClients.append(current)

        // 逐跳 jump 到后续跳板
        for hop in spec.jump.dropFirst() {
            state = .connecting(detail: String(localized: "经跳板机 → \(hop.hostname):\(String(hop.port))…"))
            current = try await current.jump(to: try settings(for: hop, useTransient: false))
            jumpClients.append(current)
        }

        // 最后 jump 到目标本机
        state = .connecting(detail: String(localized: "经跳板机 → \(spec.hostname):\(String(spec.port))…"))
        return try await current.jump(to: try settings(for: spec, useTransient: true))
    }

    /// 最外层 TCP 连接:若配了代理,先经代理再交给 Citadel;否则直连。
    private func connectEntry(to hop: HostSpec, useTransient: Bool) async throws -> SSHClient {
        let clientSettings = try settings(for: hop, useTransient: useTransient)
        guard spec.proxy.isEnabled else {
            return try await SSHClient.connect(to: clientSettings)
        }
        state = .connecting(detail: String(localized: "经代理 \(spec.proxy.host):\(String(spec.proxy.port)) 连接 \(hop.hostname):\(String(hop.port))…"))
        let proxyPassword = spec.proxy.requiresAuth
            ? try KeychainStore.read(account: KeychainStore.proxyPasswordAccount(for: spec.hostID))
            : nil
        let channel = try await ProxyConnector.connect(
            through: spec.proxy,
            proxyPassword: proxyPassword,
            to: hop.hostname,
            port: hop.port
        )
        return try await SSHClient.connect(on: channel, settings: clientSettings)
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
            // 目标或任一跳板用密钥时,连接前统一过一次 Touch ID(避免链路上多次弹窗)
            let usesKeys = ([spec] + spec.jump).contains { $0.authMethod != .password }
            if usesKeys { try await requireTouchIDIfEnabled() }
            let established = try await establishClient()
            // 跳板链所有权转入 SSHConnection,由引用计数统一管理关闭
            connection = SSHConnection(client: established, jumpClients: jumpClients)
            jumpClients = []
            connection.retain()
            client = established
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

        try await client.withPTY(ptyRequest) { inbound, outbound in
            let (stream, continuation) = AsyncStream.makeStream(of: StdinEvent.self)
            await MainActor.run {
                self.stdinWriter = continuation
                self.state = .connected
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

            // 重连恢复工作目录:先 cd 回上次目录
            if let dir = restoreDirOnConnect, !dir.isEmpty {
                restoreDirOnConnect = nil
                try? await Task.sleep(for: .milliseconds(300))
                let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
                try? await outbound.write(ByteBuffer(bytes: Array((" cd " + quoted + "\n").utf8)))
            }

            // 连接后自动执行命令(逐行发送,自动补回车)。分屏借用会话不重复执行。
            let startup = spec.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isBorrower, !startup.isEmpty {
                // 稍等 shell 提示符就绪再发,避免被吞
                try? await Task.sleep(for: .milliseconds(400))
                for line in startup.split(whereSeparator: \.isNewline) {
                    let cmd = line.trimmingCharacters(in: .whitespaces)
                    guard !cmd.isEmpty else { continue }
                    try? await outbound.write(ByteBuffer(bytes: Array((cmd + "\n").utf8)))
                    try? await Task.sleep(for: .milliseconds(120))
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

            for try await chunk in inbound {
                let buffer: ByteBuffer
                switch chunk {
                case .stdout(let b), .stderr(let b):
                    buffer = b
                }
                let bytes = Array(buffer.readableBytesView)
                await MainActor.run {
                    self.noteOutputForNotification()
                    // OSC 133 命令边界/退出码。必须先把标记之前的字节喂进终端,
                    // 再读光标行,才能拿到与标记对齐的 scroll-invariant 位置(否则记到旧位置)。
                    var fed = 0
                    for (event, offset) in self.osc133.scan(bytes[...]) {
                        if offset > fed {
                            self.terminalView.feed(byteArray: bytes[fed..<offset])
                            fed = offset
                        }
                        switch event {
                        case .commandStart:
                            self.runningCommand = true
                        case .outputStart:
                            self.runningCommand = true
                            self.commandStartedAt = Date()
                            self.pendingOutputStart = self.currentScrollInvariantRow()
                        case .commandEnd(let code):
                            self.runningCommand = false
                            self.lastExitCode = code
                            self.lastCommandDuration = self.commandStartedAt.map { Date().timeIntervalSince($0) }
                            self.commandStartedAt = nil
                            self.recordCommandOutput(code: code)
                        case .promptStart:
                            self.recordCommandMark()
                        }
                    }
                    if fed < bytes.count {
                        self.terminalView.feed(byteArray: bytes[fed...])
                    }
                    self.matchTriggers(bytes: bytes)
                }
            }
        }
    }

    /// 为某一跳(目标或跳板)构建认证方式。凭据按该跳自己的 hostID 从 Keychain 解析;
    /// useTransient 仅对目标本机成立(临时直连时用户当场输入的密码/passphrase)。
    private func authenticationMethod(for hop: HostSpec, useTransient: Bool) throws -> SSHAuthenticationMethod {
        let transientPW = useTransient ? transientPassword : nil
        let transientPP = useTransient ? transientPassphrase : nil
        switch hop.authMethod {
        case .password:
            let password = try transientPW
                ?? KeychainStore.read(account: KeychainStore.passwordAccount(for: hop.hostID))
                ?? ""
            return .passwordBased(username: hop.username, password: password)

        case .privateKeyFile:
            guard let path = hop.privateKeyPath, !path.isEmpty else { throw SessionError.unsupportedKey }
            let expanded = NSString(string: path).expandingTildeInPath
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let passphrase = try transientPP
                ?? KeychainStore.read(account: KeychainStore.passphraseAccount(for: hop.hostID))
            return try Self.keyAuthentication(username: hop.username, keyText: keyText, passphrase: passphrase)

        case .storedKey:
            guard let keyID = hop.keyID,
                  let material = try KeychainStore.read(account: KeychainStore.privateKeyAccount(for: keyID)) else {
                throw SessionError.missingStoredKey
            }
            // 生成的密钥存 raw ed25519(base64 32 字节);导入的存 OpenSSH PEM
            if let raw = Data(base64Encoded: material), raw.count == 32,
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: hop.username, privateKey: key)
            }
            let passphrase = try KeychainStore.read(account: KeychainStore.keyPassphraseAccount(for: keyID))
            return try Self.keyAuthentication(username: hop.username, keyText: material, passphrase: passphrase)

        case .agent:
            guard let agent = SSHAgentClient.fromEnvironment() else { throw AgentAuthError.noAgent }
            let identities = (try? agent.listIdentities()) ?? []
            let delegate = AgentAuthDelegate(username: hop.username, agent: agent, identities: identities)
            guard delegate.hasUsableKeys else { throw AgentAuthError.noIdentities }
            return .custom(delegate)
        }
    }

    private func hostKeyValidator(for hop: HostSpec) -> SSHHostKeyValidator {
        let validator = InteractiveHostKeyValidator(hostname: hop.hostname, port: hop.port) { [weak self] prompt in
            guard let self else { return false }
            return await self.requestHostKeyDecision(prompt)
        }
        return .custom(validator)
    }

    private func settings(for hop: HostSpec, useTransient: Bool) throws -> SSHClientSettings {
        let method = try authenticationMethod(for: hop, useTransient: useTransient)
        return SSHClientSettings(
            host: hop.hostname,
            port: hop.port,
            authenticationMethod: { method },
            hostKeyValidator: hostKeyValidator(for: hop)
        )
    }

    private static func keyAuthentication(username: String, keyText: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
            return .ed25519(username: username, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
            return .rsa(username: username, privateKey: key)
        }
        throw SessionError.unsupportedKey
    }

    /// 规格 5.4:读取私钥用于连接前可要求 Touch ID(设置项,默认开)
    private func requireTouchIDIfEnabled() async throws {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.requireTouchIDForKeys) as? Bool ?? true
        guard enabled else { return }
        state = .connecting(detail: String(localized: "等待身份验证(Touch ID)…"))
        let context = LAContext()
        do {
            // deviceOwnerAuthentication:优先生物识别,失败回退登录密码
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "使用私钥连接 \(spec.label)"))
        } catch {
            throw SessionError.authenticationGateFailed
        }
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

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            // 形如 file://host/path 或直接路径;取路径部分
            guard let dir = directory else { return }
            if let url = URL(string: dir), url.scheme == "file" {
                lastRemoteDirectory = url.path.removingPercentEncoding ?? url.path
            } else if dir.hasPrefix("/") {
                lastRemoteDirectory = dir
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
