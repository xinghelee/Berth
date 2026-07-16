import Foundation
import NIOCore

/// 极简 SOCKS5 服务端握手(仅 CONNECT,无认证),用于动态转发(-D)。
/// 从入站字节流读握手,解析出目标 host:port,回写响应;返回目标供上层开 direct-tcpip。
enum SOCKS5 {

    typealias Inbound = NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    typealias Outbound = NIOAsyncChannelOutboundWriter<ByteBuffer>

    /// 返回目标地址;失败(回写错误响应后)返回 nil。
    static func handshake(input: inout Inbound, output: Outbound) async throws -> (host: String, port: Int)? {
        var buffer = ByteBuffer()

        // 阶段 1:版本 + 方法协商 [ver, nmethods, methods...]
        guard try await fill(&buffer, to: 2, from: &input),
              buffer.readInteger(as: UInt8.self) == 5 else { return nil }
        let nmethods = Int(buffer.readInteger(as: UInt8.self) ?? 0)
        _ = try await fill(&buffer, to: nmethods, from: &input)
        buffer.moveReaderIndex(forwardBy: min(nmethods, buffer.readableBytes))
        // 选择「无认证」
        var reply = ByteBuffer()
        reply.writeBytes([0x05, 0x00])
        try await output.write(reply)

        // 阶段 2:请求 [ver, cmd, rsv, atyp, addr, port]
        buffer.discardReadBytes()
        guard try await fill(&buffer, to: 4, from: &input),
              buffer.readInteger(as: UInt8.self) == 5 else { return nil }
        let cmd = buffer.readInteger(as: UInt8.self) ?? 0
        _ = buffer.readInteger(as: UInt8.self) // rsv
        let atyp = buffer.readInteger(as: UInt8.self) ?? 0

        guard cmd == 0x01 else { // 只支持 CONNECT
            try await sendReply(0x07, output: output) // command not supported
            return nil
        }

        let host: String
        switch atyp {
        case 0x01: // IPv4
            _ = try await fill(&buffer, to: 4, from: &input)
            let bytes = buffer.readBytes(length: 4) ?? []
            host = bytes.map(String.init).joined(separator: ".")
        case 0x03: // 域名
            _ = try await fill(&buffer, to: 1, from: &input)
            let len = Int(buffer.readInteger(as: UInt8.self) ?? 0)
            _ = try await fill(&buffer, to: len, from: &input)
            host = buffer.readString(length: len) ?? ""
        case 0x04: // IPv6
            _ = try await fill(&buffer, to: 16, from: &input)
            let bytes = buffer.readBytes(length: 16) ?? []
            host = ipv6String(bytes)
        default:
            try await sendReply(0x08, output: output) // address type not supported
            return nil
        }

        _ = try await fill(&buffer, to: 2, from: &input)
        let port = Int(buffer.readInteger(as: UInt16.self) ?? 0)
        guard !host.isEmpty, port > 0 else {
            try await sendReply(0x01, output: output)
            return nil
        }

        // 成功响应(bind 地址填 0)
        try await sendReply(0x00, output: output)
        return (host, port)
    }

    /// 从流里补足 buffer 到至少 needed 可读字节;流结束返回 false
    private static func fill(_ buffer: inout ByteBuffer, to needed: Int, from input: inout Inbound) async throws -> Bool {
        while buffer.readableBytes < needed {
            guard var chunk = try await input.next() else { return false }
            buffer.writeBuffer(&chunk)
        }
        return true
    }

    private static func sendReply(_ code: UInt8, output: Outbound) async throws {
        var reply = ByteBuffer()
        reply.writeBytes([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // VER REP RSV ATYP=IPv4 0.0.0.0:0
        try await output.write(reply)
    }

    private static func ipv6String(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2).map { i in
            String(format: "%x", (Int(bytes[i]) << 8) | Int(bytes[i + 1]))
        }.joined(separator: ":")
    }
}
