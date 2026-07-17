import Foundation
import NIOCore
import NIOPosix

/// 通过 HTTP CONNECT 或 SOCKS5 代理连到目标 SSH 服务器,返回握手完成、
/// 已摘掉代理 handler 的干净 Channel,交给 Citadel 的 connect(on:settings:)。
enum ProxyConnector {

    struct ProxyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func connect(
        through proxy: ProxyConfig,
        proxyPassword: String?,
        to targetHost: String,
        port targetPort: Int,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> Channel {
        let done = group.next().makePromise(of: Void.self)
        let handler = ProxyHandshakeHandler(
            kind: proxy.kind,
            targetHost: targetHost,
            targetPort: targetPort,
            username: proxy.username,
            password: proxyPassword,
            completion: done
        )
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(host: proxy.host, port: proxy.port)
            .get()
        do {
            try await done.futureResult.get()
        } catch {
            try? await channel.close()
            throw error
        }
        return channel
    }
}

/// 在通道激活时发起代理握手,成功后把自己从 pipeline 摘除,留下干净字节管道。
final class ProxyHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case idle
        case httpAwaitingResponse
        case socksAwaitingMethod
        case socksAwaitingAuth
        case socksAwaitingReply
        case done
    }

    private let kind: ProxyKind
    private let targetHost: String
    private let targetPort: Int
    private let username: String
    private let password: String?
    private let completion: EventLoopPromise<Void>
    private var state: State = .idle
    private var accumulator = ByteBuffer()

    init(kind: ProxyKind, targetHost: String, targetPort: Int, username: String, password: String?, completion: EventLoopPromise<Void>) {
        self.kind = kind
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.username = username
        self.password = password
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        switch kind {
        case .http:
            startHTTP(context: context)
        case .socks5:
            startSOCKS(context: context)
        case .none:
            complete(context: context)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulator.writeBuffer(&buffer)
        do {
            switch state {
            case .httpAwaitingResponse: try handleHTTPResponse(context: context)
            case .socksAwaitingMethod: try handleSOCKSMethod(context: context)
            case .socksAwaitingAuth: try handleSOCKSAuthReply(context: context)
            case .socksAwaitingReply: try handleSOCKSReply(context: context)
            case .idle, .done: break
            }
        } catch {
            fail(context: context, error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state != .done {
            completion.fail(ProxyError(message: String(localized: "代理连接被关闭")))
        }
        context.fireChannelInactive()
    }

    // MARK: - HTTP CONNECT

    private func startHTTP(context: ChannelHandlerContext) {
        let target = "\(targetHost):\(targetPort)"
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let password, !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        state = .httpAwaitingResponse
        var out = context.channel.allocator.buffer(capacity: request.utf8.count)
        out.writeString(request)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    private func handleHTTPResponse(context: ChannelHandlerContext) throws {
        let bytes = accumulator.getBytes(at: accumulator.readerIndex, length: accumulator.readableBytes) ?? []
        guard let range = findCRLFCRLF(bytes) else { return } // 头未收全
        let header = String(decoding: bytes[0..<range], as: UTF8.self)
        let statusOK = header.hasPrefix("HTTP/1.1 200") || header.hasPrefix("HTTP/1.0 200")
        guard statusOK else {
            let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? header
            throw ProxyError(message: String(localized: "HTTP 代理拒绝:\(firstLine)"))
        }
        accumulator.moveReaderIndex(forwardBy: range + 4)
        complete(context: context)
    }

    // MARK: - SOCKS5

    private func startSOCKS(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 4)
        if password != nil, !username.isEmpty {
            out.writeBytes([0x05, 0x02, 0x00, 0x02]) // 支持无认证 + 用户名密码
        } else {
            out.writeBytes([0x05, 0x01, 0x00])
        }
        state = .socksAwaitingMethod
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    private func handleSOCKSMethod(context: ChannelHandlerContext) throws {
        guard accumulator.readableBytes >= 2 else { return }
        let ver = accumulator.readInteger(as: UInt8.self)!
        let method = accumulator.readInteger(as: UInt8.self)!
        guard ver == 5 else { throw ProxyError(message: String(localized: "SOCKS 版本不符")) }
        switch method {
        case 0x00:
            sendSOCKSConnect(context: context)
        case 0x02:
            guard password != nil else { throw ProxyError(message: String(localized: "代理要求认证但未提供密码")) }
            sendSOCKSAuth(context: context)
        case 0xFF:
            throw ProxyError(message: String(localized: "SOCKS 代理无可接受的认证方式"))
        default:
            throw ProxyError(message: String(localized: "SOCKS 代理选择了不支持的认证方式"))
        }
    }

    private func sendSOCKSAuth(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 3 + username.utf8.count + (password?.utf8.count ?? 0))
        out.writeInteger(UInt8(0x01))
        let user = Array(username.utf8)
        out.writeInteger(UInt8(user.count)); out.writeBytes(user)
        let pass = Array((password ?? "").utf8)
        out.writeInteger(UInt8(pass.count)); out.writeBytes(pass)
        state = .socksAwaitingAuth
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    private func handleSOCKSAuthReply(context: ChannelHandlerContext) throws {
        guard accumulator.readableBytes >= 2 else { return }
        _ = accumulator.readInteger(as: UInt8.self) // ver
        let status = accumulator.readInteger(as: UInt8.self)!
        guard status == 0 else { throw ProxyError(message: String(localized: "SOCKS 代理认证失败")) }
        sendSOCKSConnect(context: context)
    }

    private func sendSOCKSConnect(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 8 + targetHost.utf8.count)
        out.writeBytes([0x05, 0x01, 0x00, 0x03]) // CONNECT, 域名
        let host = Array(targetHost.utf8)
        out.writeInteger(UInt8(host.count)); out.writeBytes(host)
        out.writeInteger(UInt16(targetPort))
        state = .socksAwaitingReply
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    private func handleSOCKSReply(context: ChannelHandlerContext) throws {
        guard accumulator.readableBytes >= 4 else { return }
        let bytes = accumulator.getBytes(at: accumulator.readerIndex, length: 4) ?? [0, 0, 0, 0]
        guard bytes[0] == 5 else { throw ProxyError(message: String(localized: "SOCKS 回复版本不符")) }
        guard bytes[1] == 0 else { throw ProxyError(message: String(localized: "SOCKS 代理连接失败(code \(bytes[1]))")) }
        let atyp = bytes[3]
        let addrLen: Int
        switch atyp {
        case 0x01: addrLen = 4
        case 0x04: addrLen = 16
        case 0x03:
            guard accumulator.readableBytes >= 5 else { return }
            addrLen = 1 + Int(accumulator.getInteger(at: accumulator.readerIndex + 4, as: UInt8.self) ?? 0)
        default: throw ProxyError(message: String(localized: "SOCKS 回复地址类型不支持"))
        }
        let total = 4 + addrLen + 2
        guard accumulator.readableBytes >= total else { return }
        accumulator.moveReaderIndex(forwardBy: total)
        complete(context: context)
    }

    // MARK: - 收尾

    private func complete(context: ChannelHandlerContext) {
        state = .done
        // 握手后可能已收到目标服务器的首包(如 SSH banner),转交给后续 handler
        let leftover = accumulator.readableBytes > 0 ? accumulator.slice() : nil
        let channel = context.channel
        context.pipeline.removeHandler(self).whenComplete { _ in
            if let leftover {
                channel.pipeline.fireChannelRead(NIOAny(leftover))
            }
            self.completion.succeed(())
        }
    }

    private func fail(context: ChannelHandlerContext, _ error: Error) {
        guard state != .done else { return }
        state = .done
        completion.fail(error)
        context.close(promise: nil)
    }

    private func findCRLFCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i+1] == 10 && bytes[i+2] == 13 && bytes[i+3] == 10 {
            return i
        }
        return nil
    }
}

private typealias ProxyError = ProxyConnector.ProxyError
