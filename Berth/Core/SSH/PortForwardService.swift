import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// 端口转发运行时:给定已连接的 SSHClient 和一组转发规格,建立并维持各条转发。
/// - local:本地 ServerBootstrap 监听,每个入连接开一条 direct-tcpip 到远端目标并对拷字节。
/// - dynamic:同上,但入连接前先做 SOCKS5 握手,按 CONNECT 目标开 direct-tcpip。
/// - remote:Citadel 一等公民 runRemotePortForward(远端监听 → 回连本地目标)。
///
/// 每条转发的运行态回调到 statusHandler(在主线程更新 UI)。
final class PortForwardService: @unchecked Sendable {

    enum ForwardState: Equatable, Sendable {
        case starting
        case active(boundPort: Int)
        case failed(String)
    }

    private let client: SSHClient
    private let group: EventLoopGroup
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let statusHandler: @Sendable (UUID, ForwardState) -> Void

    init(client: SSHClient, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
         statusHandler: @escaping @Sendable (UUID, ForwardState) -> Void) {
        self.client = client
        self.group = group
        self.statusHandler = statusHandler
    }

    func start(_ forwards: [PortForwardSpec]) {
        for forward in forwards {
            statusHandler(forward.id, .starting)
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    switch forward.kind {
                    case .local, .dynamic:
                        try await self.runListener(forward)
                    case .remote:
                        try await self.runRemote(forward)
                    }
                } catch is CancellationError {
                    // 正常停止
                } catch {
                    self.statusHandler(forward.id, .failed(Self.message(for: error)))
                }
            }
            tasks[forward.id] = task
        }
    }

    func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    // MARK: - 本地 / 动态:监听本地端口

    private func runListener(_ forward: PortForwardSpec) async throws {
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: forward.bindHost, port: forward.bindPort) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }

        let boundPort = server.channel.localAddress?.port ?? forward.bindPort
        statusHandler(forward.id, .active(boundPort: boundPort))

        try await server.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { taskGroup in
                for try await accepted in inbound {
                    taskGroup.addTask { [weak self] in
                        guard let self else { return }
                        try? await self.handleAccepted(accepted, forward: forward)
                    }
                }
            }
        }
    }

    private func handleAccepted(_ accepted: NIOAsyncChannel<ByteBuffer, ByteBuffer>, forward: PortForwardSpec) async throws {
        try await accepted.executeThenClose { localIn, localOut in
            var iterator = localIn.makeAsyncIterator()

            // 目标地址:local 直接用配置;dynamic 先 SOCKS5 握手拿到目标
            let target: (host: String, port: Int)
            if forward.kind == .dynamic {
                guard let resolved = try await SOCKS5.handshake(input: &iterator, output: localOut) else { return }
                target = resolved
            } else {
                target = (forward.targetHost, forward.targetPort)
            }

            let remote = try await openDirectTCPIP(host: target.host, port: target.port)

            try await remote.executeThenClose { remoteIn, remoteOut in
                try await withThrowingTaskGroup(of: Void.self) { pipe in
                    // 本地 → 远端:结束后半关远端写,让远端收到 EOF
                    pipe.addTask {
                        while let chunk = try await iterator.next() {
                            try await remoteOut.write(chunk)
                        }
                        remoteOut.finish()
                    }
                    // 远端 → 本地:结束后半关本地写
                    pipe.addTask {
                        for try await chunk in remoteIn {
                            try await localOut.write(chunk)
                        }
                        localOut.finish()
                    }
                    // 两个方向都排空后才收尾(半关而非粗暴取消,避免丢未 flush 的数据)
                    try await pipe.waitForAll()
                }
            }
        }
    }

    private func openDirectTCPIP(host: String, port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        // 在 initialize 闭包(通道自身 event loop、开始读取之前)里包装,
        // 否则通道返回后 autoRead 可能已把首包(如 SSH banner)投递丢失。
        let box = NIOLockedValueBox<NIOAsyncChannel<ByteBuffer, ByteBuffer>?>(nil)
        _ = try await client.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: host,
                targetPort: port,
                originatorAddress: originator
            )
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                box.withLockedValue { $0 = wrapped }
            }
        }
        guard let wrapped = box.withLockedValue({ $0 }) else {
            throw CitadelError.channelCreationFailed
        }
        return wrapped
    }

    // MARK: - 远程转发

    private func runRemote(_ forward: PortForwardSpec) async throws {
        // 远端监听 bindHost:bindPort,每个入连接回连本地 targetHost:targetPort。
        // 用低层 withRemotePortForward 自己对拷(Citadel 的 runRemotePortForward 用了
        // 一端结束即 cancelAll 的写法,会丢未 flush 数据),对拷用半关。
        let handler = statusHandler
        let id = forward.id
        let localHost = forward.targetHost
        let localPort = forward.targetPort
        let group = self.group

        try await client.withRemotePortForward(
            host: forward.bindHost,
            port: forward.bindPort,
            inboundType: ByteBuffer.self,
            outboundType: ByteBuffer.self,
            onOpen: { remote in handler(id, .active(boundPort: remote.boundPort)) },
            onAccept: { incoming in
                let local = try await ClientBootstrap(group: group)
                    .connect(host: localHost, port: localPort)
                    .flatMapThrowing { channel in
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                    .get()
                try await Self.pipe(incoming, local)
            }
        )
    }

    /// 两个 NIOAsyncChannel 之间双向对拷,半关收尾(不丢未 flush 的数据)
    private static func pipe(
        _ a: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        _ b: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    ) async throws {
        try await a.executeThenClose { inA, outA in
            try await b.executeThenClose { inB, outB in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await chunk in inA { try await outB.write(chunk) }
                        outB.finish()
                    }
                    group.addTask {
                        for try await chunk in inB { try await outA.write(chunk) }
                        outA.finish()
                    }
                    try await group.waitForAll()
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("addressInUse") || raw.localizedCaseInsensitiveContains("in use") {
            return "端口已被占用"
        }
        if raw.localizedCaseInsensitiveContains("permission") {
            return "无权限绑定该端口(<1024 需特权)"
        }
        return "转发失败:\(raw)"
    }
}
