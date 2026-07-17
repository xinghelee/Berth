import Foundation

/// SSH agent 协议客户端(阻塞式 unix socket)。用于 ssh-agent 认证:
/// `signature(for:)` 是同步的,故这里同步收发。见 OpenSSH PROTOCOL.agent。
struct SSHAgentClient {

    struct AgentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Identity {
        let keyBlob: Data   // SSH wire 公钥(string keytype + …)
        let comment: String
        /// blob 首字段解析出的密钥类型,如 ssh-ed25519 / ssh-rsa
        var keyType: String {
            var reader = SSHWireReader(keyBlob)
            return reader.readString() ?? ""
        }
    }

    // 消息号
    private static let requestIdentities: UInt8 = 11
    private static let identitiesAnswer: UInt8 = 12
    private static let signRequest: UInt8 = 13
    private static let signResponse: UInt8 = 14

    let socketPath: String

    /// 从 SSH_AUTH_SOCK 创建;没有则 nil
    static func fromEnvironment() -> SSHAgentClient? {
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !path.isEmpty else { return nil }
        return SSHAgentClient(socketPath: path)
    }

    func listIdentities() throws -> [Identity] {
        let response = try roundTrip(type: Self.requestIdentities, payload: Data())
        var reader = SSHWireReader(response)
        guard let type = reader.readByte(), type == Self.identitiesAnswer else {
            throw AgentError(message: String(localized: "agent 未返回身份列表"))
        }
        guard let count = reader.readUInt32() else { throw AgentError(message: String(localized: "agent 响应格式错误")) }
        var identities: [Identity] = []
        for _ in 0..<count {
            guard let blob = reader.readData(), let comment = reader.readString() else { break }
            identities.append(Identity(keyBlob: blob, comment: comment))
        }
        return identities
    }

    /// 返回完整签名 blob(string sigformat + string sigblob)
    func sign(keyBlob: Data, data: Data, flags: UInt32) throws -> Data {
        var writer = SSHWireWriter()
        writer.writeData(keyBlob)
        writer.writeData(data)
        writer.writeUInt32(flags)
        let response = try roundTrip(type: Self.signRequest, payload: writer.data)
        var reader = SSHWireReader(response)
        guard let type = reader.readByte(), type == Self.signResponse else {
            throw AgentError(message: String(localized: "agent 签名被拒绝"))
        }
        guard let signature = reader.readData() else { throw AgentError(message: String(localized: "agent 签名响应格式错误")) }
        return signature
    }

    // MARK: - 帧收发(阻塞)

    private func roundTrip(type: UInt8, payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError(message: String(localized: "无法创建 socket")) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentError(message: String(localized: "SSH_AUTH_SOCK 路径过长"))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw AgentError(message: String(localized: "连不上 ssh-agent(\(socketPath))")) }

        // 发送:uint32 length + byte type + payload
        var frame = Data()
        var length = UInt32(1 + payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type)
        frame.append(payload)
        try writeAll(fd: fd, data: frame)

        // 读取:uint32 length + payload
        let header = try readExact(fd: fd, count: 4)
        let respLen = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard respLen > 0, respLen < 1_000_000 else { throw AgentError(message: String(localized: "agent 响应长度异常")) }
        return try readExact(fd: fd, count: Int(respLen))
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { throw AgentError(message: String(localized: "写 agent 失败")) }
                sent += n
            }
        }
    }

    private func readExact(fd: Int32, count: Int) throws -> Data {
        var buffer = Data(count: count)
        try buffer.withUnsafeMutableBytes { raw in
            var received = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while received < count {
                let n = read(fd, base + received, count - received)
                if n <= 0 { throw AgentError(message: String(localized: "读 agent 失败")) }
                received += n
            }
        }
        return buffer
    }
}

// MARK: - SSH wire 编解码

struct SSHWireReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    mutating func readByte() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        let value = data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readData() -> Data? {
        guard let len = readUInt32(), offset + Int(len) <= data.endIndex else { return nil }
        let slice = data[offset..<offset+Int(len)]
        offset += Int(len)
        return Data(slice)
    }

    mutating func readString() -> String? {
        readData().flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 剩余未读字节
    func remaining() -> Data {
        Data(data[offset..<data.endIndex])
    }
}

struct SSHWireWriter {
    private(set) var data = Data()
    mutating func writeUInt32(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    mutating func writeData(_ blob: Data) {
        writeUInt32(UInt32(blob.count))
        data.append(blob)
    }
}
