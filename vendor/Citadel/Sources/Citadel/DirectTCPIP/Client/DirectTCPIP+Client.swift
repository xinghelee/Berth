import NIO
import NIOSSH

// [Berth patch] public,以便 remote 转发的 forwarded-tcpip 入通道在 configure 闭包里
// 手动安装此 codec(direct-tcpip 是自动装的,forwarded-tcpip 不是,否则 NIOAsyncChannel
// 收不到 ByteBuffer)。
public final class DataToBufferCodec: ChannelDuplexHandler {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    public init() {}

    public func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let bytes) = data.data else {
            fatalError("Unexpected read type")
        }

        guard case .channel = data.type else {
            context.fireErrorCaught(SSHChannelError.invalidDataType)
            return
        }

        context.fireChannelRead(self.wrapInboundOut(bytes))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

extension SSHClient {
    /// Creates a new direct TCP/IP channel. This channel type is used to open a TCP/IP connection to a remote host, through the remote SSH server.
    public func createDirectTCPIPChannel(
        using settings: SSHChannelType.DirectTCPIP,
        initialize: @escaping (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        return try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler] in
            let createdChannel = eventLoop.makePromise(of: Channel.self)
            sshHandler.value.createChannel(
                createdChannel,
                channelType: .directTCPIP(settings)
            ) { channel, type in
                guard case .directTCPIP = type else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.channelCreationFailed)
                }
                
                do {
                    try channel.pipeline.syncOperations.addHandler(DataToBufferCodec())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return initialize(channel)
            }
            
            return createdChannel.futureResult
        }.get()
    }
}
