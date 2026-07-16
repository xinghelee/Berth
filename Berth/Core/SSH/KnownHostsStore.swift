import Crypto
import Foundation
import NIOCore
import NIOSSH

/// ~/.ssh/known_hosts 读写,与命令行 ssh 互通。
/// 支持明文主机名与 hashed(|1|salt|hash,HMAC-SHA1)条目;
/// 非 22 端口使用 [host]:port 记法;写入采用明文主机名(与 HashKnownHosts no 一致)。
struct KnownHostsStore {

    enum Evaluation: Equatable {
        /// 主机已知且密钥一致
        case trusted
        /// 主机从未见过(或没有该类型密钥的记录)
        case unknown
        /// 主机已知但密钥变了 —— 安全关键路径
        case mismatch(knownFingerprints: [String])
    }

    struct Entry {
        var hostPatterns: [String]   // 明文 pattern;hashed 条目此数组为空
        var hashedPattern: (salt: Data, hash: Data)?
        var keyType: String
        var keyBlobBase64: String
        var rawLine: String
    }

    let path: String

    init(path: String = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath) {
        self.path = path
    }

    // MARK: - 查询

    func evaluate(hostname: String, port: Int, presentedKey: NIOSSHPublicKey) -> Evaluation {
        let hostToken = Self.hostToken(hostname: hostname, port: port)
        let presentedType = Self.keyType(of: presentedKey)
        let presentedBlob = Self.keyBlobBase64(of: presentedKey)

        var sawHost = false
        var knownFingerprints: [String] = []

        for entry in entries() where Self.entryMatches(entry, hostToken: hostToken) {
            sawHost = true
            if entry.keyType == presentedType {
                if entry.keyBlobBase64 == presentedBlob {
                    return .trusted
                }
                if let data = Data(base64Encoded: entry.keyBlobBase64) {
                    knownFingerprints.append(Self.fingerprint(ofBlob: data))
                }
            }
        }

        if sawHost && !knownFingerprints.isEmpty {
            return .mismatch(knownFingerprints: knownFingerprints)
        }
        // 主机有记录但没有该类型的密钥:按未知处理(提示确认后追加)
        return .unknown
    }

    // MARK: - 写入

    /// 首次信任:追加条目
    func append(hostname: String, port: Int, key: NIOSSHPublicKey) throws {
        let line = "\(Self.hostToken(hostname: hostname, port: port)) \(Self.keyType(of: key)) \(Self.keyBlobBase64(of: key))\n"
        try ensureFileExists()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// 密钥变更且用户显式确认后:移除该主机同类型旧条目再追加新条目
    func replace(hostname: String, port: Int, key: NIOSSHPublicKey) throws {
        let hostToken = Self.hostToken(hostname: hostname, port: port)
        let keyType = Self.keyType(of: key)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        let kept = text.components(separatedBy: .newlines).filter { line in
            guard let entry = Self.parseLine(line) else { return true }
            return !(Self.entryMatches(entry, hostToken: hostToken) && entry.keyType == keyType)
        }
        let joined = kept.joined(separator: "\n")
        try joined.write(toFile: path, atomically: true, encoding: .utf8)
        try append(hostname: hostname, port: port, key: key)
    }

    // MARK: - 指纹

    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        fingerprint(ofBlob: keyBlob(of: key))
    }

    /// OpenSSH 风格:SHA256:<base64 无填充>
    static func fingerprint(ofBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    static func keyType(of key: NIOSSHPublicKey) -> String {
        // blob 首字段即 keytype 字符串:uint32 长度 + ascii
        let blob = keyBlob(of: key)
        guard blob.count >= 4 else { return "unknown" }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard blob.count >= 4 + length, length > 0, length < 64 else { return "unknown" }
        return String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8) ?? "unknown"
    }

    static func keyBlob(of key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    static func keyBlobBase64(of key: NIOSSHPublicKey) -> String {
        keyBlob(of: key).base64EncodedString()
    }

    // MARK: - 解析

    func entries() -> [Entry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap(Self.parseLine)
    }

    static func parseLine(_ line: String) -> Entry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        // @revoked / @cert-authority 标记条目暂不参与匹配
        guard !trimmed.hasPrefix("@") else { return nil }

        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return nil }
        let hostField = String(fields[0])
        let keyType = String(fields[1])
        let blob = String(fields[2])

        if hostField.hasPrefix("|1|") {
            let parts = hostField.dropFirst(3).split(separator: "|")
            guard parts.count == 2,
                  let salt = Data(base64Encoded: String(parts[0])),
                  let hash = Data(base64Encoded: String(parts[1])) else { return nil }
            return Entry(hostPatterns: [], hashedPattern: (salt, hash), keyType: keyType, keyBlobBase64: blob, rawLine: line)
        }
        return Entry(
            hostPatterns: hostField.split(separator: ",").map(String.init),
            hashedPattern: nil,
            keyType: keyType,
            keyBlobBase64: blob,
            rawLine: line
        )
    }

    static func entryMatches(_ entry: Entry, hostToken: String) -> Bool {
        if let hashed = entry.hashedPattern {
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(hostToken.utf8), using: SymmetricKey(data: hashed.salt))
            return Data(mac) == hashed.hash
        }
        var matched = false
        for pattern in entry.hostPatterns {
            if pattern.hasPrefix("!") {
                if SSHConfigParser.wildcardMatch(hostToken, pattern: String(pattern.dropFirst())) { return false }
            } else if SSHConfigParser.wildcardMatch(hostToken, pattern: pattern) {
                matched = true
            }
        }
        return matched
    }

    /// known_hosts 的主机记法:22 端口用裸主机名,否则 [host]:port
    static func hostToken(hostname: String, port: Int) -> String {
        port == 22 ? hostname : "[\(hostname)]:\(port)"
    }

    private func ensureFileExists() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: path) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
}
