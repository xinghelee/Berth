#if canImport(AppKit)
import AppKit
#endif
import Citadel
import Foundation
import UniformTypeIdentifiers
import NIOCore

/// Bridges worker-thread progress to the observable browser state.  Disk and network work never
/// calls the MainActor directly; updates are already throttled by SFTPDownloadEngine.
@MainActor
private final class SFTPDownloadProgressSink {
    private let progress: Progress?
    private let apply: (SFTPDownloadEngine.ProgressUpdate) -> Void

    init(
        progress: Progress?,
        apply: @escaping (SFTPDownloadEngine.ProgressUpdate) -> Void
    ) {
        self.progress = progress
        self.apply = apply
    }

    func consume(_ update: SFTPDownloadEngine.ProgressUpdate) {
        if update.isFinished {
            // Foundation Progress treats a zero-byte transfer as indeterminate unless it has a
            // positive total.  Represent the completed empty file as one logical unit so Finder
            // receives a deterministic 1/1 completion event.
            let total = max(1, update.totalBytes ?? update.completedBytes)
            progress?.totalUnitCount = Int64(clamping: total)
            progress?.completedUnitCount = progress?.totalUnitCount ?? 1
        } else if let totalBytes = update.totalBytes {
            progress?.totalUnitCount = Int64(clamping: max(1, totalBytes))
            progress?.completedUnitCount = min(
                progress?.totalUnitCount ?? 0,
                Int64(clamping: update.completedBytes)
            )
        }
        apply(update)
    }
}

enum SFTPTransferCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.userCancelled.rawValue)
            || Task.isCancelled
    }

    static func normalizedError(_ error: Error) -> Error {
        isCancellation(error) ? CocoaError(.userCancelled) : error
    }
}

/// SFTP 文件浏览:复用会话 SSHClient 打开 SFTP,维护当前目录与条目,提供上传/下载/增删改。
@MainActor
@Observable
final class SFTPBrowser {

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64
        /// `SFTPFileAttributes.size` is optional.  Preserve that distinction so a reported zero
        /// byte file can skip READ entirely while an unknown-size file still uses EOF fallback.
        let sizeIsKnown: Bool
        let modified: Date?
        var permissions: UInt32 = 0
        /// 权限低 9 位(rwxrwxrwx)
        var mode: UInt32 { permissions & 0o777 }
    }

    /// 目录下载扫描时使用的轻量条目,与 Citadel 类型解耦,便于覆盖递归与符号链接边界。
    struct DownloadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
        let sizeIsKnown: Bool

        init(name: String, kind: Kind, size: UInt64, sizeIsKnown: Bool = true) {
            self.name = name
            self.kind = kind
            self.size = size
            self.sizeIsKnown = sizeIsKnown
        }
    }

    /// 目录上传扫描时使用的轻量条目(issue #17),与下载侧对称,便于覆盖递归与符号链接边界
    struct UploadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
    }

    struct UploadTreeFile: Equatable, Sendable {
        let localURL: URL
        let relativeComponents: [String]
        let size: UInt64
    }

    struct DirectoryUploadPlan: Equatable, Sendable {
        var directories: [[String]] = []
        var files: [UploadTreeFile] = []
        var totalBytes: UInt64 = 0
        var skippedSymlinks = 0
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 一次进行中的传输。并发传输(如连拖两个文件下载)各持独立条目,
    /// 互不覆盖标签/进度,先完成的只清自己,不会把别人的进度条带走。
    struct ActiveTransfer: Identifiable, Equatable {
        let id: UUID
        var label: String
        /// 0...1;nil 表示不确定(扫描中/体积未知)
        var progress: Double?
        var isCancelling: Bool
        var canCancel: Bool

        init(
            id: UUID,
            label: String,
            progress: Double? = nil,
            isCancelling: Bool = false,
            canCancel: Bool = false
        ) {
            self.id = id
            self.label = label
            self.progress = progress
            self.isCancelling = isCancelling
            self.canCancel = canCancel
        }
    }

    private(set) var state: State = .idle
    private(set) var path = "/"
    /// 登录 home,供路径输入的 ~ 展开
    private(set) var homePath = "/"
    private(set) var entries: [Entry] = []
    /// 进行中的传输,按开始顺序排列;空表示空闲
    private(set) var transfers: [ActiveTransfer] = []

    private var sftp: SFTPClient?
    public let configuration: SFTPTransferConfiguration
    /// One budget per browser/SFTP session.  Concurrent drag and panel downloads share this cap
    /// instead of creating an independent request window for every file or directory.
    private let transferBudget: SFTPDownloadEngine.TransferBudget
    private let opener: () async throws -> SFTPClient
    /// 打开后首先落在哪个目录(取该 pane 终端的当前目录);nil 或列不出来时回落 home
    private let initialPath: String?
    /// 面板已关闭:打开中(await opener)被关时,迟到的 client 要立即关掉,不能泄漏子通道
    private var isClosed = false
    /// 通道失效后重开时回到的目录(上次成功列出的目录);首次打开用 initialPath
    private var resumePath: String?
    /// 通道死掉后是否已经自动重开过一次(成功列目录即复位),服务端每次都秒断时不至于无限循环
    private var reopenedAfterFailure = false
    /// 列目录看门狗:远端目录挂在僵死的 NFS 上时 READDIR 永远不回,不能让面板一直转圈。
    /// 到点不直接判死——大目录在高延迟链路上要几百次 READDIR 往返——而是先在同一通道上 stat 探活。
    /// 实例属性便于验收测试注入更短的超时
    var listingTimeout: Duration = .seconds(20)
    /// 探活 stat 的等待上限;stat 也不回才算通道挂了
    var probeTimeout: Duration = .seconds(10)
    /// 上传/下载与列目录共用一条 SFTP 子通道,看门狗关通道会把在途传输一起杀掉
    /// (表现为上传进度行凭空消失、浏览随即自动恢复)。探活也无回应时,若有传输在途,
    /// 先按此轮数推迟判死(每轮 = listingTimeout + probeTimeout)给传输让路;
    /// 轮次用尽(通道真挂死且传输也卡住)才照旧关通道自愈
    static let maxWatchdogDeferrals = 2

    init(
        initialPath: String? = nil,
        configuration: SFTPTransferConfiguration = .init(),
        opener: @escaping () async throws -> SFTPClient
    ) {
        let normalized = configuration.normalized
        self.initialPath = initialPath
        self.configuration = normalized
        self.transferBudget = SFTPDownloadEngine.TransferBudget(configuration: normalized)
        self.opener = opener
    }

    #if DEBUG
    /// 测试专用初始化方法: 强制校验注入的 transferBudget 与 configuration 必须绝对一致
    init(
        initialPath: String? = nil,
        configuration: SFTPTransferConfiguration,
        testBudget: SFTPDownloadEngine.TransferBudget,
        opener: @escaping () async throws -> SFTPClient
    ) {
        let normalized = configuration.normalized
        precondition(
            testBudget.configuration == normalized,
            "TransferBudget configuration must match SFTPBrowser configuration"
        )
        self.initialPath = initialPath
        self.configuration = normalized
        self.transferBudget = testBudget
        self.opener = opener
    }
    #endif

    /// 打开 SFTP 并列出首个目录:该 pane 终端的当前目录,列不出来回落 home
    func start() async { await open(listing: initialPath) }

    /// 打开子通道后列出 target(nil = home;列不出来回落 home)。子通道打开可能被服务器
    /// 无响应地挂住(sshd 未启用 SFTP 子系统 / MaxSessions 限制),15s 看门狗置失败态可重试。
    private func open(listing target: String?) async {
        guard sftp == nil, state != .loading else { return }
        Task { _ = try? await SFTPDragStagingStore.shared.sweepStale() }
        state = .loading
        let opening = Task { try await self.opener() }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.state == .loading, self.sftp == nil else { return }
            opening.cancel()
            self.state = .failed(String(localized: "打开 SFTP 超时:服务器可能未启用 SFTP 子系统或已达会话上限,点刷新重试。"))
            // 迟到的 client 直接关掉,不能泄漏子通道
            Task.detached { if let late = try? await opening.value { try? await late.close() } }
        }
        do {
            let client = try await opening.value
            watchdog.cancel()
            if isClosed || state != .loading {
                Task.detached { try? await client.close() }
                return
            }
            sftp = client
            let home = (try? await client.getRealPath(atPath: ".")) ?? "/"
            homePath = home
            if let target, target != home {
                await list(path: target)
                // 目标目录可能已被删/无权限,回落 home;通道在等待期间又换了就不动
                if case .failed = state, sftp === client { await list(path: home) }
            } else {
                await list(path: home)
            }
        } catch {
            // 看门狗超时置败后,opening 被 cancel 抛错到这里,不要覆盖超时提示
            if state == .loading { state = .failed(friendly(error)) }
        }
    }

    /// 已连上则重新列目录;通道未开/已丢弃(面板先于连接打开、断线、超时、被杀)则重开并回到原目录
    func refresh() async {
        if sftp == nil {
            await open(listing: resumePath ?? initialPath)
        } else {
            await list(path: path)
        }
    }

    func enter(_ entry: Entry) async {
        guard entry.isDirectory || entry.isSymlink else { return }
        await list(path: join(path, entry.name))
    }

    func goUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await list(path: parent.isEmpty ? "/" : parent)
    }

    /// 手输路径跳转:支持 ~、~/xxx 与相对当前目录的路径
    func navigate(to newPath: String) async {
        var target = newPath.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if target == "~" {
            target = homePath
        } else if target.hasPrefix("~/") {
            target = join(homePath, String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = join(path, target)
        }
        if target.count > 1, target.hasSuffix("/") { target.removeLast() }
        await list(path: target)
    }

    private func list(path newPath: String) async {
        // 通道已丢弃(断线/超时/被杀):先重开,直接落到目标目录,挂住的那个目录不必再等一次看门狗
        guard let sftp else {
            await open(listing: newPath)
            return
        }
        state = .loading
        let listing = Task { try await sftp.listDirectory(atPath: newPath) }
        var outcome = await Self.result(of: listing, within: listingTimeout)
        var watchdogDeferrals = 0
        while outcome == nil {
            // 超时不等于死了:先发一个 stat 探活(任何回应,包括出错,都说明通道活着,只是目录大/链路慢),
            // 有回应就继续等;stat 也不回才关掉通道让挂起的请求失败,下次刷新自动开一条新通道
            guard self.sftp === sftp else { return }
            let probe = Task { try await sftp.getAttributes(at: newPath) }
            guard await Self.result(of: probe, within: probeTimeout) != nil else {
                guard self.sftp === sftp else { return }
                // 有传输在途时先不关通道:上传/下载与列目录共用这条子通道,现在关会把传输一起杀掉
                // (切换目录误杀上传的根因)。推迟一轮继续等列表结果;轮次用尽才判死,
                // 保证通道真挂死且传输也卡住时仍能自愈,不引入新的永久卡死路径
                if !transfers.isEmpty, watchdogDeferrals < Self.maxWatchdogDeferrals {
                    watchdogDeferrals += 1
                    outcome = await Self.result(of: listing, within: listingTimeout)
                    continue
                }
                dropClient()
                state = .failed(String(localized: "SFTP 无响应,点刷新重新打开。"))
                return
            }
            outcome = await Self.result(of: listing, within: listingTimeout)
        }
        // 等待期间通道可能已被换掉(断线重连/超时重开),迟到的结果不能覆盖新通道的状态
        guard self.sftp === sftp, let outcome else { return }
        switch outcome {
        case .success(let names):
            let components = names.flatMap(\.components)
            let mapped: [Entry] = components.compactMap { component in
                let name = component.filename
                guard name != ".", name != ".." else { return nil }
                let type = fileType(component)
                return Entry(
                    name: name,
                    isDirectory: type == .directory,
                    isSymlink: type == .symlink,
                    size: component.attributes.size ?? 0,
                    sizeIsKnown: component.attributes.size != nil,
                    modified: component.attributes.accessModificationTime?.modificationTime,
                    permissions: component.attributes.permissions ?? 0
                )
            }
            entries = mapped.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            path = newPath
            resumePath = newPath
            reopenedAfterFailure = false
            state = .ready
        case .failure(let error):
            await handleFailure(error, retrying: newPath)
        }
    }

    // MARK: - 通道失效恢复

    /// 各操作的统一失败出口:通道死了走重开流程,其余只提示。
    /// 通道已被别处丢弃(断线/看门狗)时保留那边的提示,不让迟到的 connectionClosed 盖掉。
    private func handleFailure(_ error: Error, retrying target: String? = nil) async {
        guard let sftp else {
            if !Self.isDeadChannelError(error) { state = .failed(friendly(error)) }
            return
        }
        if !sftp.isActive || Self.isDeadChannelError(error) {
            await reopenAfterDeadChannel(listing: target)
        } else {
            state = .failed(friendly(error))
        }
    }

    /// 通道已死(会话重连换了连接、服务端关掉了 sftp 子系统、看门狗关的):丢掉旧客户端,
    /// 自动重开一次落到 target(默认原目录);再失败就停在失败态,等用户操作或会话重连时由面板触发。
    private func reopenAfterDeadChannel(listing target: String? = nil) async {
        dropClient()
        state = .failed(String(localized: "SFTP 通道已断开,点刷新重新打开。"))
        guard !reopenedAfterFailure else { return }
        reopenedAfterFailure = true
        await open(listing: target ?? resumePath ?? initialPath)
    }

    /// 终端会话断线:子通道随连接一起没了,立即丢掉客户端;重连后由面板调 refresh() 重开
    func connectionLost() {
        guard sftp != nil else { return }
        dropClient()
        state = .failed(String(localized: "连接已断开,重连后自动恢复。"))
    }

    private func dropClient() {
        guard let client = sftp else { return }
        sftp = nil
        Task.detached { try? await client.close() }
    }

    private static func isDeadChannelError(_ error: Error) -> Bool {
        if case SFTPError.connectionClosed = error { return true }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .eof: return true
            default: return false
            }
        }
        return false
    }

    /// 等任务出结果或超时;超时返回 nil。任务不取消:Citadel 的请求等待不响应取消,
    /// 调用方靠关通道让它失败,任务随后自行结束。
    private static func result<T: Sendable>(of task: Task<T, Error>, within timeout: Duration) async -> Result<T, Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            let gate = ResumeGate()
            Task {
                let outcome = await task.result
                if gate.claim() { continuation.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - 传输

    /// 本地上传的读取块大小(256KB):摊薄往返开销,同时避免整文件读入内存
    private static let uploadChunkSize = 256 * 1024

    private var downloadTasks: [UUID: Task<SFTPDownloadEngine.SFTPDownloadResult, Error>] = [:]
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    struct DownloadExecution {
        let entry: Entry
        let remotePath: String
        let localURL: URL
        let sftp: SFTPClient?
        let budget: SFTPDownloadEngine.TransferBudget
        let configuration: SFTPTransferConfiguration
        let onPlan: @Sendable (SFTPDownloadEngine.DirectoryPlan) async -> Void
        let onProgress: @Sendable (SFTPDownloadEngine.ProgressUpdate) async -> Void
    }

    typealias DownloadExecutor = @Sendable (DownloadExecution) async throws -> SFTPDownloadEngine.SFTPDownloadResult

    static let defaultDownloadExecutor: DownloadExecutor = { request in
        guard let sftp = request.sftp else { throw TransferError.sftpUnavailable }
        if request.entry.isDirectory {
            let plan = try await SFTPDownloadEngine.downloadDirectory(
                remoteRoot: request.remotePath,
                localRoot: request.localURL,
                sftp: sftp,
                budget: request.budget,
                configuration: request.configuration,
                onPlan: request.onPlan,
                onProgress: request.onProgress
            )
            return SFTPDownloadEngine.SFTPDownloadResult(copiedBytes: plan.copiedBytes)
        } else {
            let copiedBytes = try await SFTPDownloadEngine.downloadFile(
                remotePath: request.remotePath,
                expectedSize: request.entry.sizeIsKnown ? request.entry.size : nil,
                localURL: request.localURL,
                sftp: sftp,
                budget: request.budget,
                configuration: request.configuration,
                onProgress: request.onProgress
            )
            return SFTPDownloadEngine.SFTPDownloadResult(copiedBytes: copiedBytes)
        }
    }

    var downloadExecutor: DownloadExecutor = SFTPBrowser.defaultDownloadExecutor

    private func beginTransfer(_ label: String, progress: Double? = nil, canCancel: Bool = false) -> UUID {
        let id = UUID()
        transfers.append(ActiveTransfer(
            id: id,
            label: label,
            progress: progress,
            isCancelling: false,
            canCancel: canCancel
        ))
        return id
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].canCancel, !transfers[index].isCancelling else { return }
        transfers[index].isCancelling = true
        if let handler = cancellationHandlers[id] {
            handler()
        } else {
            downloadTasks[id]?.cancel()
        }
    }

    private func setTransfer(_ id: UUID, label: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].label = label
    }

    private func setTransfer(_ id: UUID, progress: Double?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = progress
    }

    private func endTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    func download(_ entry: Entry, to localURL: URL) async {
        do {
            // Freeze the selected remote directory before the first suspension. Destination
            // preparation performs file-system work on another actor; the user may navigate the
            // SFTP panel while it is running, but that must not retarget this download.
            let remoteDirectory = path
            let worker = DownloadDestinationTransactionWorker.shared
            let tx = try await worker.begin(
                finalURL: localURL,
                isDirectory: entry.isDirectory
            )
            do {
                try Task.checkCancellation()
                try await performDownload(
                    entry,
                    remoteDirectory: remoteDirectory,
                    to: tx.workingURL,
                    externalProgress: nil
                )
                try Task.checkCancellation()
                try await worker.commit(tx)
            } catch {
                await worker.discard(tx)
                throw error
            }
        } catch where SFTPTransferCancellation.isCancellation(error) {
            // 用户主动取消, 不改变 state 为 .failed
        } catch {
            await handleFailure(error)
        }
    }

    /// Finder 拖出下载使用。拖拽开始时冻结 remoteDirectory,避免传输过程中切换目录后
    /// 同名文件被解析到新的当前位置。错误必须继续抛给 NSItemProvider,让 Finder 显示失败。
    @discardableResult
    func downloadForDrag(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        progress: Progress
    ) async throws -> SFTPDownloadEngine.SFTPDownloadResult {
        try await performDownload(
            entry,
            remoteDirectory: remoteDirectory,
            to: localURL,
            externalProgress: progress
        )
    }

    @discardableResult
    private func performDownload(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        externalProgress: Progress?
    ) async throws -> SFTPDownloadEngine.SFTPDownloadResult {
        // The top-level name is server-controlled too. Validate it before opening a handle or
        // touching the caller-provided local destination; recursive entries are validated by the
        // download engine while it builds the directory plan.
        try LocalPathComponentValidator.validateComponent(entry.name)
        let remotePath = join(remoteDirectory, entry.name)
        let transferID = beginTransfer(
            entry.isDirectory
                ? String(localized: "扫描 \(entry.name)…")
                : String(localized: "下载 \(entry.name)…"),
            progress: !entry.isDirectory && entry.size > 0 ? 0 : nil,
            canCancel: true
        )
        let sink = SFTPDownloadProgressSink(progress: externalProgress) { [weak self] update in
            guard let self else { return }
            if let totalBytes = update.totalBytes, totalBytes > 0 {
                self.setTransfer(transferID, progress: min(
                    1,
                    Double(update.completedBytes) / Double(totalBytes)
                ))
            } else if update.isFinished {
                self.setTransfer(transferID, progress: 1)
            }
        }
        let onProgress: @Sendable (SFTPDownloadEngine.ProgressUpdate) async -> Void = { update in
            await MainActor.run {
                sink.consume(update)
            }
        }

        let onPlan: @Sendable (SFTPDownloadEngine.DirectoryPlan) async -> Void = { [weak self] plan in
            guard let self else { return }
            await MainActor.run {
                self.setTransfer(transferID, label: plan.skippedSymlinks > 0
                    ? String(localized: "下载 \(entry.name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
                    : String(localized: "下载 \(entry.name)…"))
            }
        }

        let transferTask = Task { [weak self] () -> SFTPDownloadEngine.SFTPDownloadResult in
            guard let self else { throw CancellationError() }
            return try await self.downloadExecutor(DownloadExecution(
                entry: entry,
                remotePath: remotePath,
                localURL: localURL,
                sftp: self.sftp,
                budget: self.transferBudget,
                configuration: self.configuration,
                onPlan: onPlan,
                onProgress: onProgress
            ))
        }
        downloadTasks[transferID] = transferTask
        if let externalProgress {
            cancellationHandlers[transferID] = { [weak externalProgress] in
                externalProgress?.cancel()
                transferTask.cancel()
            }
        } else {
            cancellationHandlers[transferID] = {
                transferTask.cancel()
            }
        }
        defer {
            cancellationHandlers.removeValue(forKey: transferID)
            downloadTasks.removeValue(forKey: transferID)
            endTransfer(transferID)
        }

        if Task.isCancelled {
            transferTask.cancel()
        }

        return try await withTaskCancellationHandler {
            let result = try await transferTask.value
            // Task cancellation is cooperative: a custom/finishing executor may return success
            // after cancelTransfer() has already cancelled it. Never let that race reach commit().
            if transferTask.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            return result
        } onCancel: {
            transferTask.cancel()
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    /// 递归删除的执行顺序:先删文件与符号链接(链接删自身、不跟随),再按「最深优先」
    /// 删目录(rmdir 只认空目录)。root 排在 directories 最后。
    struct DirectoryDeletePlan: Equatable, Sendable {
        var removals: [String] = []
        var directories: [String] = []
    }

    static func makeDirectoryDeletePlan(
        remoteRoot: String,
        list: (_ remotePath: String) async throws -> [DownloadTreeEntry]
    ) async throws -> DirectoryDeletePlan {
        var plan = DirectoryDeletePlan()

        func scan(remotePath: String) async throws {
            try Task.checkCancellation()
            for entry in try await list(remotePath) {
                guard entry.name != ".", entry.name != ".." else { continue }
                let childPath = remotePath == "/" ? "/\(entry.name)" : "\(remotePath)/\(entry.name)"
                switch entry.kind {
                case .directory:
                    try await scan(remotePath: childPath)
                case .file, .symlink:
                    plan.removals.append(childPath)
                }
            }
            plan.directories.append(remotePath)
        }

        try await scan(remotePath: remoteRoot)
        return plan
    }

    /// 上传前先扫描本地目录树(issue #17),与下载 plan 对称:符号链接不跟随,
    /// 避免循环与把树外目标意外上传;list 可注入便于测试。
    static func makeDirectoryUploadPlan(
        localRoot: URL,
        list: (_ url: URL) throws -> [UploadTreeEntry]
    ) throws -> DirectoryUploadPlan {
        var plan = DirectoryUploadPlan()

        func scan(url: URL, relativeComponents: [String]) throws {
            try Task.checkCancellation()
            plan.directories.append(relativeComponents)
            for entry in try list(url) {
                let childURL = url.appendingPathComponent(entry.name)
                let childComponents = relativeComponents + [entry.name]
                switch entry.kind {
                case .directory:
                    try scan(url: childURL, relativeComponents: childComponents)
                case .file:
                    plan.files.append(UploadTreeFile(
                        localURL: childURL,
                        relativeComponents: childComponents,
                        size: entry.size
                    ))
                    plan.totalBytes = saturatingAdd(plan.totalBytes, entry.size)
                case .symlink:
                    plan.skippedSymlinks += 1
                }
            }
        }

        try scan(url: localRoot, relativeComponents: [])
        return plan
    }

    /// 生产用的本地目录列举:先判符号链接(symlink 指向目录时 isDirectory 会随目标为真,
    /// 判断顺序反了就会跟着链接走);按名字排序保证顺序稳定。
    static func listLocalDirectory(_ url: URL) throws -> [UploadTreeEntry] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        return try contents.map { child in
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let kind: UploadTreeEntry.Kind = values.isSymbolicLink == true
                ? .symlink
                : (values.isDirectory == true ? .directory : .file)
            return UploadTreeEntry(
                name: child.lastPathComponent,
                kind: kind,
                size: UInt64(clamping: values.fileSize ?? 0)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 流式分块上传单个本地文件(大文件不整读进内存)。面板与终端拖拽共用。
    @discardableResult
    static func uploadLocalFile(
        _ localURL: URL,
        to remotePath: String,
        sftp: SFTPClient,
        onProgress: (_ copied: UInt64) -> Void = { _ in }
    ) async throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: localURL)
        do {
            let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let data = try handle.read(upToCount: uploadChunkSize), !data.isEmpty else { break }
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await file.write(buffer, at: offset)
                    offset += UInt64(data.count)
                    onProgress(offset)
                }
                if offset == 0 {
                    // 空文件也要建出来
                    try await file.write(ByteBufferAllocator().buffer(capacity: 0), at: 0)
                }
                try await file.close()
                try handle.close()
                return offset
            } catch {
                try? await file.close()
                try? handle.close()
                throw error
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// 递归上传整个目录:扫描出 plan → 建远端目录 → 逐文件流式上传。
    /// createDirectory 的失败不当场报错(目录可能已存在,语义是合并);
    /// 若确实建不出来,随后第一个文件写入会抛出更明确的错误。
    static func performDirectoryUpload(
        localRoot: URL,
        remoteRoot: String,
        sftp: SFTPClient,
        onPlan: (DirectoryUploadPlan) -> Void = { _ in },
        onProgress: (_ copied: UInt64, _ total: UInt64) -> Void = { _, _ in }
    ) async throws {
        let plan = try makeDirectoryUploadPlan(localRoot: localRoot, list: listLocalDirectory)
        onPlan(plan)

        for components in plan.directories {
            try Task.checkCancellation()
            let remote = components.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            try? await sftp.createDirectory(atPath: remote)
        }

        var completedBytes: UInt64 = 0
        for item in plan.files {
            try Task.checkCancellation()
            let remote = item.relativeComponents.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            let base = completedBytes
            let copied = try await uploadLocalFile(item.localURL, to: remote, sftp: sftp) { fileBytes in
                onProgress(saturatingAdd(base, fileBytes), plan.totalBytes)
            }
            completedBytes = saturatingAdd(completedBytes, copied)
        }
        onProgress(completedBytes, plan.totalBytes)
    }

    /// 上传文件或整个目录(issue #17):目录先扫描再递归,文件流式分块不整读进内存
    /// - Parameter directory: 远端目标目录;nil = 当前目录(右键目录行「上传到此文件夹」传子目录,issue #36)
    func upload(from localURL: URL, into directory: String? = nil) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        let remoteDirectory = directory ?? path
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        let transferID = beginTransfer(isDir.boolValue
            ? String(localized: "扫描 \(name)…")
            : String(localized: "上传 \(name)…"))
        defer { endTransfer(transferID) }
        do {
            if isDir.boolValue {
                try await Self.performDirectoryUpload(
                    localRoot: localURL,
                    remoteRoot: join(remoteDirectory, name),
                    sftp: sftp,
                    onPlan: { plan in
                        setTransfer(transferID, label: plan.skippedSymlinks > 0
                            ? String(localized: "上传 \(name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
                            : String(localized: "上传 \(name)…"))
                        setTransfer(transferID, progress: plan.totalBytes > 0 ? 0 : nil)
                    },
                    onProgress: { copied, total in
                        if total > 0 {
                            setTransfer(transferID, progress: min(1, Double(copied) / Double(total)))
                        }
                    }
                )
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
                setTransfer(transferID, progress: size > 0 ? 0 : nil)
                try await Self.uploadLocalFile(localURL, to: join(remoteDirectory, name), sftp: sftp) { copied in
                    if size > 0 {
                        setTransfer(transferID, progress: min(1, Double(copied) / Double(size)))
                    }
                }
            }
            await refresh()
        } catch {
            await handleFailure(error)
        }
    }

    // MARK: - 服务端文件编辑(下载 → 本地编辑器 → 保存自动回传)

    /// 用设置里指定的编辑器打开本地临时副本;未指定(或指定的 app 已不存在)则按
    /// `systemEditorApplication(for:)` 的规则挑程序。
    private static func openWithPreferredEditor(_ url: URL, workspace: URL? = nil) {
        #if canImport(AppKit)
        let customPath = UserDefaults.standard.string(forKey: SettingsKeys.externalEditorPath) ?? ""
        if !customPath.isEmpty {
            let editorURL = URL(fileURLWithPath: customPath)
            if FileManager.default.fileExists(atPath: customPath) {
                // 引用的资源落在文档目录之外(`../shared/x.png`)时,VS Code 一类编辑器的预览只认
                // 工作区内的本地资源:能开文件夹的编辑器(Info.plist 声明 public.folder)就把共同
                // 祖先目录当工作区一起打开;其余编辑器仍只开文件
                var items = [url]
                if let workspace, editorAcceptsFolders(at: editorURL) { items.insert(workspace, at: 0) }
                NSWorkspace.shared.open(items, withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(
            [url], withApplicationAt: systemEditorApplication(for: url), configuration: NSWorkspace.OpenConfiguration()
        )
        #endif
    }

    #if canImport(AppKit)
    /// 未指定编辑器时用哪个程序。文件名(含扩展名)由服务器决定,不能无条件交给 LaunchServices
    /// 按扩展名挑默认程序:notes.terminal / .webloc / .command / .mobileconfig 会被直接「执行」而不是编辑。
    /// issue #46:.yaml/.json/.md 这类纯文本类型、且 macOS 为它指定的默认程序本身是文本编辑器
    /// (声明能开纯文本、不是浏览器)时,尊重用户的默认应用;其余一律系统纯文本编辑器。
    /// 两道门的规则见 `RemoteEditOpenPolicy`。
    static func systemEditorApplication(for url: URL) -> URL {
        let plainTextEditor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard let type = RemoteEditOpenPolicy.textType(forFilenameExtension: url.pathExtension),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            return plainTextEditor
        }
        let urlTypes = (Bundle(url: handler)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        let plainTextApps = NSWorkspace.shared.urlsForApplications(toOpen: UTType.plainText)
        let trusted = RemoteEditOpenPolicy.isTrustedEditor(handler, plainTextApps: plainTextApps, urlSchemes: schemes)
        return trusted ? handler : plainTextEditor
    }
    #endif

    /// 编辑器的 Info.plist 是否把文件夹声明为可打开的文档类型(VS Code、Cursor、Zed 等都声明)
    private static func editorAcceptsFolders(at appURL: URL) -> Bool {
        guard let types = Bundle(url: appURL)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return false
        }
        return types.contains { type in
            ((type["LSItemContentTypes"] as? [String]) ?? []).contains { $0 == "public.folder" || $0 == "public.directory" }
        }
    }

    /// 正在编辑中的远端文件(远端绝对路径 → 状态),供 UI 显示角标
    private(set) var editing: [String: EditState] = [:]
    enum EditState: Equatable { case syncing, idle, failed }
    @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
    /// 已在编辑的远端路径 → 本地临时副本(供再次点击时直接重开编辑器)
    @ObservationIgnored private var editLocalURLs: [String: URL] = [:]
    /// 已在编辑的远端路径 → 需要一起打开的工作区目录(资源落在文档目录之外时才有)
    @ObservationIgnored private var editWorkspaces: [String: URL] = [:]

    /// 双击文件时:拉到本地临时目录,用默认编辑器打开,轮询本地改动自动回传到原路径。
    /// openInEditor=false 仅供自动化验收(不真的启动编辑器),返回本地临时文件路径。
    @discardableResult
    func editRemotely(_ entry: Entry, openInEditor: Bool = true) -> URL? {
        guard let sftp, !entry.isDirectory else { return nil }
        let remotePath = join(path, entry.name)
        // 已在编辑:直接重开已有本地副本,不再重复下载/新建监听
        if editTasks[remotePath] != nil {
            if let existing = editLocalURLs[remotePath], openInEditor {
                Self.openWithPreferredEditor(existing, workspace: editWorkspaces[remotePath])
            }
            return editLocalURLs[remotePath]
        }

        // 本地副本按远端绝对路径镜像存放(issue #34):md/html 里 `diagrams/x.svg`、`../a.png`
        // 这类相对引用在编辑器预览里才对得上,顺带把它们拉下来放到对应位置
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-edit-\(UUID().uuidString)", isDirectory: true)
        guard let components = RemoteEditAssets.components(of: remotePath),
              let localURL = try? LocalPathComponentValidator.safeURL(in: dir, components: components) else {
            return nil
        }
        editLocalURLs[remotePath] = localURL

        editing[remotePath] = .syncing
        let budget = transferBudget
        let configuration = self.configuration
        let task = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                // 下载走下载引擎:按实际读到的字节推进,服务器谎报大小/提前 EOF 都能正确收尾。
                // 不用 Citadel 的 readAll():它按 FSTAT 大小循环,超量 DATA 会整数下溢崩溃,
                // 提前 EOF 会无限发 READ,而且整个文件都在内存里
                _ = try await SFTPDownloadEngine.downloadFile(
                    remotePath: remotePath,
                    expectedSize: entry.sizeIsKnown ? entry.size : nil,
                    localURL: localURL,
                    sftp: sftp,
                    budget: budget,
                    configuration: configuration
                )
                // 引用的资源先于编辑器打开就位,预览首次渲染就有图;拉不到不影响主文件编辑
                let assets = await Self.fetchReferencedAssets(
                    of: remotePath, localURL: localURL, root: dir,
                    sftp: sftp, budget: budget, configuration: configuration
                )
                let workspace = RemoteEditAssets.workspaceRoot(document: localURL, assets: assets, within: dir)
                await MainActor.run {
                    self?.editing[remotePath] = .idle
                    self?.editWorkspaces[remotePath] = workspace
                    if openInEditor { Self.openWithPreferredEditor(localURL, workspace: workspace) }
                }
                await self?.watchAndSync(localURL: localURL, remotePath: remotePath)
            } catch {
                await MainActor.run { self?.editing[remotePath] = .failed }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        editTasks[remotePath] = task
        return localURL
    }

    /// issue #34:md/html 打开前顺带把它相对引用的资源拉到镜像位置。尽力而为:只看直接引用,
    /// 最多 32 个、单个 ≤20MB、总量 ≤64MB、整体 15 秒,超出就跳过;目录/不存在/拉失败都跳过。
    /// 这些资源只下载不回传,编辑回传仍只管主文件。返回成功落地的本地路径。
    private static func fetchReferencedAssets(
        of remotePath: String,
        localURL: URL,
        root: URL,
        sftp: SFTPClient,
        budget: SFTPDownloadEngine.TransferBudget,
        configuration: SFTPTransferConfiguration
    ) async -> [URL] {
        guard RemoteEditAssets.isScannable(localURL.lastPathComponent),
              let handle = try? FileHandle(forReadingFrom: localURL) else { return [] }
        let data = (try? handle.read(upToCount: RemoteEditAssets.maxScanBytes)) ?? Data()
        try? handle.close()
        guard !data.isEmpty else { return [] }
        let directory = (remotePath as NSString).deletingLastPathComponent
        var targets: [(remote: String, local: URL)] = []
        var seen: Set<String> = [remotePath]
        for reference in RemoteEditAssets.relativeReferences(in: String(decoding: data, as: UTF8.self)) {
            guard let resolved = RemoteEditAssets.resolve(reference, relativeTo: directory),
                  seen.insert(resolved).inserted,
                  let components = RemoteEditAssets.components(of: resolved),
                  let local = try? LocalPathComponentValidator.safeURL(in: root, components: components)
            else { continue }
            targets.append((resolved, local))
            if targets.count >= RemoteEditAssets.maxFiles { break }
        }
        guard !targets.isEmpty else { return [] }
        let deadline = ContinuousClock.now + .seconds(15)
        var total: UInt64 = 0
        var downloaded: [URL] = []
        for target in targets {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            // stat 跟随符号链接;跳过目录与过大的文件
            guard let attributes = try? await sftp.getAttributes(at: target.remote),
                  let size = attributes.size,
                  size <= RemoteEditAssets.maxFileBytes,
                  total + size <= RemoteEditAssets.maxTotalBytes,
                  attributes.permissions.map({ $0 & 0o170000 != 0o040000 }) ?? true
            else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: target.local.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                total += try await SFTPDownloadEngine.downloadFile(
                    remotePath: target.remote,
                    expectedSize: size,
                    localURL: target.local,
                    sftp: sftp,
                    budget: budget,
                    configuration: configuration
                )
                downloaded.append(target.local)
            } catch {
                try? FileManager.default.removeItem(at: target.local)
            }
        }
        return downloaded
    }

    /// 轮询本地文件 mtime,变化即回传(对 vim/VSCode 的原子保存-重命名也可靠)
    private func watchAndSync(localURL: URL, remotePath: String) async {
        func mtime() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
        }
        var lastModified = mtime()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1200))
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            let current = mtime()
            guard current != lastModified else { continue }
            lastModified = current
            editing[remotePath] = .syncing
            do {
                // 用当前通道回传:断线重连/超时重开换过通道后,编辑会话不必重来
                guard let sftp else { throw TransferError.sftpUnavailable }
                let data = try Data(contentsOf: localURL)
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: 0)
                try? await file.close()
                editing[remotePath] = .idle
                if path == (remotePath as NSString).deletingLastPathComponent { await refresh() }
            } catch {
                editing[remotePath] = .failed
            }
        }
    }

    func stopEditing(_ remotePath: String) {
        editTasks[remotePath]?.cancel()
        editTasks[remotePath] = nil
        editLocalURLs[remotePath] = nil
        editWorkspaces[remotePath] = nil
        editing[remotePath] = nil
    }

    // MARK: - chmod / 预览 / 书签

    /// 修改权限(保留文件类型高位,仅换低 12 位)
    func chmod(_ entry: Entry, mode: UInt32) async {
        guard let sftp else { return }
        do {
            var attrs = SFTPFileAttributes()
            attrs.permissions = (entry.permissions & ~0o7777) | (mode & 0o7777)
            try await sftp.setAttributes(at: join(path, entry.name), to: attrs)
            await refresh()
        } catch {
            await handleFailure(error)
        }
    }

    /// 预览上限:列表里的大小是服务器说的,真读时仍按此截断,多读到一个字节就判定过大
    static let previewLimit = 256 * 1024

    /// 快速预览:下载小文本文件(≤256KB)返回内容;过大或二进制返回 nil
    func previewText(_ entry: Entry) async -> String? {
        guard let sftp, !entry.isDirectory, entry.size <= UInt64(Self.previewLimit) else { return nil }
        do {
            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            let data: Data?
            do {
                data = try await Self.readPrefix(of: file, limit: Self.previewLimit)
            } catch {
                try? await file.close()
                throw error
            }
            try? await file.close()
            guard let data else { return nil }
            // 含 NUL 视为二进制
            if data.prefix(8000).contains(0) { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// 从头最多读 limit 字节;文件比 limit 长返回 nil。每次 READ 按实际返回长度推进,
    /// 服务器回空 DATA/EOF 即停,不依赖 FSTAT 报的大小(Citadel readAll 的下溢/死循环根源)。
    private static func readPrefix(of file: SFTPFile, limit: Int) async throws -> Data? {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        let chunk: UInt32 = 32 * 1024
        while data.count <= limit {
            var buffer = try await file.read(from: UInt64(data.count), length: chunk)
            guard buffer.readableBytes > 0,
                  let bytes = buffer.readBytes(length: buffer.readableBytes) else { break }
            data.append(contentsOf: bytes)
            if data.count > limit { return nil }
        }
        return data
    }

    // 书签(常用远端目录,全局持久化)
    private static let bookmarksKey = "sftp.bookmarks"
    private(set) var bookmarks: [String] = UserDefaults.standard.stringArray(forKey: SFTPBrowser.bookmarksKey) ?? []

    func toggleBookmark() {
        if let idx = bookmarks.firstIndex(of: path) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(path)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    var isCurrentBookmarked: Bool { bookmarks.contains(path) }

    func makeDirectory(name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: join(path, name))
            await refresh()
        } catch {
            await handleFailure(error)
        }
    }

    /// 删除文件/符号链接直接 remove;目录递归删除(rmdir 只认空目录,非空必须先清内容)
    func delete(_ entry: Entry) async { await delete([entry]) }

    /// 批量删除:逐个删,全部结束后只刷新一次;中途出错停下并提示。
    /// 目录在开始时冻结,删除期间切目录不会把后面的项解析到新位置。
    func delete(_ entries: [Entry]) async {
        guard let sftp, !entries.isEmpty else { return }
        let directory = path
        do {
            for entry in entries {
                try Task.checkCancellation()
                try await remove(entry, in: directory, using: sftp)
            }
            await refresh()
        } catch {
            await handleFailure(error)
        }
    }

    private func remove(_ entry: Entry, in directory: String, using sftp: SFTPClient) async throws {
        let full = join(directory, entry.name)
        guard entry.isDirectory else {
            try await sftp.remove(at: full)
            return
        }
        let transferID = beginTransfer(String(localized: "删除 \(entry.name)…"))
        defer { endTransfer(transferID) }
        let plan = try await Self.makeDirectoryDeletePlan(remoteRoot: full) { path in
            let names = try await sftp.listDirectory(atPath: path)
            return names.flatMap(\.components).compactMap { component in
                guard component.filename != ".", component.filename != ".." else { return nil }
                let kind: DownloadTreeEntry.Kind = switch fileType(component) {
                case .directory: .directory
                case .symlink: .symlink
                case .file: .file
                }
                return DownloadTreeEntry(
                    name: component.filename, kind: kind,
                    size: component.attributes.size ?? 0
                )
            }
        }
        let total = plan.removals.count + plan.directories.count
        var done = 0
        for removal in plan.removals {
            try Task.checkCancellation()
            try await sftp.remove(at: removal)
            done += 1
            setTransfer(transferID, progress: Double(done) / Double(total))
        }
        for directory in plan.directories {
            try Task.checkCancellation()
            try await sftp.rmdir(at: directory)
            done += 1
            setTransfer(transferID, progress: Double(done) / Double(total))
        }
    }

    func rename(_ entry: Entry, to newName: String) async {
        guard let sftp, !newName.isEmpty, newName != entry.name else { return }
        do {
            try await sftp.rename(at: join(path, entry.name), to: join(path, newName))
            await refresh()
        } catch {
            await handleFailure(error)
        }
    }

    func close() {
        isClosed = true
        for task in editTasks.values { task.cancel() }
        editTasks = [:]
        editLocalURLs = [:]
        editWorkspaces = [:]
        editing = [:]
        for handler in cancellationHandlers.values { handler() }
        cancellationHandlers = [:]
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]
        let client = sftp
        sftp = nil
        Task.detached { try? await client?.close() }
    }

    // MARK: - 工具

    private enum FileType { case directory, symlink, file }

    private enum TransferError: LocalizedError {
        case sftpUnavailable

        var errorDescription: String? {
            switch self {
            case .sftpUnavailable: String(localized: "SFTP 连接不可用")
            }
        }
    }

    private func fileType(_ component: SFTPPathComponent) -> FileType {
        if let permissions = component.attributes.permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .file
            }
        }
        // permissions 缺失时看 ls -l 首字符
        switch component.longname.first {
        case "d": return .directory
        case "l": return .symlink
        default: return .file
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func friendly(_ error: Error) -> String {
        if Self.isDeadChannelError(error) { return String(localized: "SFTP 通道已断开,点刷新重新打开。") }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("permission") { return String(localized: "权限不足") }
        if raw.localizedCaseInsensitiveContains("noSuchFile") || raw.localizedCaseInsensitiveContains("no such") {
            return String(localized: "文件或目录不存在")
        }
        return String(localized: "SFTP 操作失败:\(raw)")
    }
}

/// 本地编辑时随主文件一起拉下来的引用资源(issue #34):从 md/html 里找相对路径引用,
/// 解析成远端绝对路径;本地按远端绝对路径镜像存放,所以 `../` 也能对上。纯函数,便于单测。
enum RemoteEditAssets {
    static let scannableExtensions: Set<String> = ["md", "markdown", "mdx", "html", "htm"]
    static let maxFiles = 32
    static let maxFileBytes: UInt64 = 20 * 1024 * 1024
    static let maxTotalBytes: UInt64 = 64 * 1024 * 1024
    /// 只扫文档开头这么多字节,超大文件不整份读进内存
    static let maxScanBytes = 2 * 1024 * 1024

    static func isScannable(_ fileName: String) -> Bool {
        scannableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private static let patterns: [NSRegularExpression] = [
        // Markdown 图片/链接:![alt](path "title")、[text](<path with spaces>)
        try! NSRegularExpression(pattern: #"\]\(\s*<?([^)\s>]+)>?"#),
        // Markdown 引用式定义:[id]: path
        try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]]+\]:\s*<?(\S+)>?"#),
        // HTML:src="..." / href='...'
        try! NSRegularExpression(pattern: #"(?i)\b(?:src|href)\s*=\s*["']([^"']+)["']"#),
    ]

    /// 提取相对引用:丢掉带 scheme 的 URL(http:/data:/mailto:…)、`//host`、绝对路径、纯锚点,
    /// 去掉 ?query 与 #fragment,做百分号解码;按出现顺序去重
    static func relativeReferences(in text: String) -> [String] {
        let ns = text as NSString
        var matches: [(Int, String)] = []
        for pattern in patterns {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
                matches.append((match.range(at: 1).location, ns.substring(with: match.range(at: 1))))
            }
        }
        var seen: Set<String> = []
        var result: [String] = []
        for (_, raw) in matches.sorted(by: { $0.0 < $1.0 }) {
            guard let reference = normalize(raw), seen.insert(reference).inserted else { continue }
            result.append(reference)
        }
        return result
    }

    private static func normalize(_ raw: String) -> String? {
        var reference = raw.trimmingCharacters(in: .whitespaces)
        if let hash = reference.firstIndex(of: "#") { reference = String(reference[..<hash]) }
        if let query = reference.firstIndex(of: "?") { reference = String(reference[..<query]) }
        reference = reference.removingPercentEncoding ?? reference
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.hasSuffix("/") else { return nil }
        if let colon = reference.firstIndex(of: ":") {
            let scheme = reference[..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) {
                return nil
            }
        }
        return reference
    }

    /// 编辑器会自动读取的目录:恶意文档引用 `.vscode/tasks.json` 之类不该被拉进镜像工作区
    /// (VS Code 的 Restricted Mode 本身也挡,这里不给这个口子);`.github/logo.png` 这类照常
    static let skippedDirectories: Set<String> = [".vscode", ".git", ".idea"]

    /// 相对引用 → 远端绝对路径;`..` 越过根目录的丢弃,落在编辑器配置目录里的丢弃
    static func resolve(_ reference: String, relativeTo directory: String) -> String? {
        var stack = directory.split(separator: "/").map(String.init)
        for part in reference.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: stack.append(String(part))
            }
        }
        guard !stack.isEmpty,
              !stack.dropLast().contains(where: { skippedDirectories.contains($0.lowercased()) })
        else { return nil }
        return "/" + stack.joined(separator: "/")
    }

    /// 有资源落在文档目录之外(`../shared/x.png`)时,返回文档目录与这些资源目录的共同祖先,
    /// 供能开文件夹的编辑器当工作区一起打开(VS Code 的预览只认工作区内的本地资源);
    /// 资源都在文档目录内则返回 nil。祖先不会高过镜像根目录。
    static func workspaceRoot(document: URL, assets: [URL], within root: URL) -> URL? {
        let documentDirectory = document.deletingLastPathComponent().pathComponents
        let outside = assets
            .map { $0.deletingLastPathComponent().pathComponents }
            .filter { !$0.starts(with: documentDirectory) }
        guard !outside.isEmpty else { return nil }
        var common = documentDirectory
        for directory in outside {
            let shared = zip(common, directory).prefix { $0 == $1 }.count
            common = Array(common.prefix(shared))
        }
        let rootComponents = root.pathComponents
        if common.count < rootComponents.count { common = rootComponents }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    /// 远端绝对路径 → 本地镜像用的分量,每段都过 LocalPathComponentValidator
    static func components(of absolutePath: String) -> [String]? {
        let components = absolutePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components {
            guard (try? LocalPathComponentValidator.validateComponent(component)) != nil else { return nil }
        }
        return components
    }
}

/// 只允许第一次认领成功:超时与结果两条路径谁先到谁 resume,另一条静默放弃
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String], directory: Bool) -> URL {
        components.enumerated().reduce(self) { url, pair in
            let (index, component) = pair
            return url.appendingPathComponent(
                component,
                isDirectory: index < components.count - 1 || directory
            )
        }
    }
}
