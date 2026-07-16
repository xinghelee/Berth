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

    private var sftp: SFTPClient?
    private let opener: () async throws -> SFTPClient

    init(opener: @escaping () async throws -> SFTPClient) {
        self.opener = opener
    }

    /// 打开 SFTP 并列出 home 目录
    func start() async {
        guard sftp == nil else { return }
        state = .loading
        do {
            let client = try await opener()
            sftp = client
            let home = (try? await client.getRealPath(atPath: ".")) ?? "/"
            await list(path: home)
        } catch {
            state = .failed(friendly(error))
        }
    }

    func refresh() async { await list(path: path) }

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

    func download(_ entry: Entry, to localURL: URL) async {
        guard let sftp, !entry.isDirectory else { return }
        transfer = "下载 \(entry.name)…"
        defer { transfer = nil }
        do {
            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            let buffer = try await file.readAll()
            try? await file.close()
            let data = Data(buffer.readableBytesView)
            try data.write(to: localURL)
        } catch {
            state = .failed(friendly(error))
        }
    }

    func upload(from localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        transfer = "上传 \(name)…"
        defer { transfer = nil }
        do {
            let data = try Data(contentsOf: localURL)
            let file = try await sftp.openFile(
                filePath: join(path, name),
                flags: [.write, .create, .truncate]
            )
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer, at: 0)
            try? await file.close()
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
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
