import AppKit
import Citadel
import Foundation
import NIOCore

/// SFTP 文件浏览:复用会话 SSHClient 打开 SFTP,维护当前目录与条目,提供上传/下载/增删改。
@MainActor
@Observable
final class SFTPBrowser {

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64
        let modified: Date?
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var path = "/"
    private(set) var entries: [Entry] = []
    /// 正在传输的说明(上传/下载),nil 表示空闲
    private(set) var transfer: String?
    /// 传输进度 0...1;nil 表示不确定(体积未知/小文件)
    private(set) var transferProgress: Double?

    private var sftp: SFTPClient?
    private let opener: () async throws -> SFTPClient
    /// 面板已关闭:打开中(await opener)被关时,迟到的 client 要立即关掉,不能泄漏子通道
    private var isClosed = false

    init(opener: @escaping () async throws -> SFTPClient) {
        self.opener = opener
    }

    /// 打开 SFTP 并列出 home 目录
    func start() async {
        guard sftp == nil, state != .loading else { return }
        state = .loading
        do {
            let client = try await opener()
            if isClosed {
                Task.detached { try? await client.close() }
                return
            }
            sftp = client
            let home = (try? await client.getRealPath(atPath: ".")) ?? "/"
            await list(path: home)
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// 已连上则重新列目录;打开失败/未打开(如面板先于连接打开)则重试整个打开流程
    func refresh() async {
        if sftp == nil {
            await start()
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

    func navigate(to newPath: String) async {
        await list(path: newPath)
    }

    private func list(path newPath: String) async {
        guard let sftp else { return }
        state = .loading
        do {
            let names = try await sftp.listDirectory(atPath: newPath)
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
                    modified: component.attributes.accessModificationTime?.modificationTime
                )
            }
            entries = mapped.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            path = newPath
            state = .ready
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 传输

    /// 分块传输的块大小(256KB):够大以摊薄往返开销,又够小以更新进度
    private static let chunkSize = 256 * 1024

    func download(_ entry: Entry, to localURL: URL) async {
        guard let sftp, !entry.isDirectory else { return }
        transfer = "下载 \(entry.name)…"
        transferProgress = entry.size > 0 ? 0 : nil
        defer { transfer = nil; transferProgress = nil }
        do {
            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            defer { Task { try? await file.close() } }
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while true {
                let buffer = try await file.read(from: offset, length: UInt32(Self.chunkSize))
                let count = buffer.readableBytes
                if count == 0 { break }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(count)
                if entry.size > 0 { transferProgress = min(1, Double(offset) / Double(entry.size)) }
                if count < Self.chunkSize { break }
            }
        } catch {
            state = .failed(friendly(error))
        }
    }

    func upload(from localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        transfer = "上传 \(name)…"
        defer { transfer = nil; transferProgress = nil }
        do {
            let data = try Data(contentsOf: localURL)
            let total = data.count
            transferProgress = total > 0 ? 0 : nil
            let file = try await sftp.openFile(
                filePath: join(path, name),
                flags: [.write, .create, .truncate]
            )
            defer { Task { try? await file.close() } }
            var offset = 0
            while offset < total {
                let end = min(offset + Self.chunkSize, total)
                var buffer = ByteBufferAllocator().buffer(capacity: end - offset)
                buffer.writeBytes(data[offset..<end])
                try await file.write(buffer, at: UInt64(offset))
                offset = end
                transferProgress = Double(offset) / Double(total)
            }
            if total == 0 {
                // 空文件也要建出来
                try await file.write(ByteBufferAllocator().buffer(capacity: 0), at: 0)
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 服务端文件编辑(下载 → 本地编辑器 → 保存自动回传)

    /// 正在编辑中的远端文件(远端绝对路径 → 状态),供 UI 显示角标
    private(set) var editing: [String: EditState] = [:]
    enum EditState: Equatable { case syncing, idle, failed }
    @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
    /// 已在编辑的远端路径 → 本地临时副本(供再次点击时直接重开编辑器)
    @ObservationIgnored private var editLocalURLs: [String: URL] = [:]

    /// 双击文件时:拉到本地临时目录,用默认编辑器打开,轮询本地改动自动回传到原路径。
    /// openInEditor=false 仅供自动化验收(不真的启动编辑器),返回本地临时文件路径。
    @discardableResult
    func editRemotely(_ entry: Entry, openInEditor: Bool = true) -> URL? {
        guard let sftp, !entry.isDirectory else { return nil }
        let remotePath = join(path, entry.name)
        // 已在编辑:直接重开已有本地副本,不再重复下载/新建监听
        if editTasks[remotePath] != nil {
            if let existing = editLocalURLs[remotePath], openInEditor {
                NSWorkspace.shared.open(existing)
            }
            return editLocalURLs[remotePath]
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-edit-\(UUID().uuidString)", isDirectory: true)
        let localURL = dir.appendingPathComponent(entry.name)
        editLocalURLs[remotePath] = localURL

        editing[remotePath] = .syncing
        let task = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // 下载
                let file = try await sftp.openFile(filePath: remotePath, flags: .read)
                let buffer = try await file.readAll()
                try? await file.close()
                try Data(buffer.readableBytesView).write(to: localURL)
                await MainActor.run {
                    self?.editing[remotePath] = .idle
                    if openInEditor { NSWorkspace.shared.open(localURL) }
                }
                await self?.watchAndSync(localURL: localURL, remotePath: remotePath, sftp: sftp)
            } catch {
                await MainActor.run { self?.editing[remotePath] = .failed }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        editTasks[remotePath] = task
        return localURL
    }

    /// 轮询本地文件 mtime,变化即回传(对 vim/VSCode 的原子保存-重命名也可靠)
    private func watchAndSync(localURL: URL, remotePath: String, sftp: SFTPClient) async {
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
        editing[remotePath] = nil
    }

    func makeDirectory(name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: join(path, name))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func delete(_ entry: Entry) async {
        guard let sftp else { return }
        do {
            let full = join(path, entry.name)
            if entry.isDirectory {
                try await sftp.rmdir(at: full)
            } else {
                try await sftp.remove(at: full)
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func rename(_ entry: Entry, to newName: String) async {
        guard let sftp, !newName.isEmpty, newName != entry.name else { return }
        do {
            try await sftp.rename(at: join(path, entry.name), to: join(path, newName))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func close() {
        isClosed = true
        for task in editTasks.values { task.cancel() }
        editTasks = [:]
        editLocalURLs = [:]
        editing = [:]
        let client = sftp
        sftp = nil
        Task.detached { try? await client?.close() }
    }

    // MARK: - 工具

    private enum FileType { case directory, symlink, file }

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
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("permission") { return "权限不足" }
        if raw.localizedCaseInsensitiveContains("noSuchFile") || raw.localizedCaseInsensitiveContains("no such") {
            return "文件或目录不存在"
        }
        return "SFTP 操作失败:\(raw)"
    }
}
