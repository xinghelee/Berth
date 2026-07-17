import Foundation
import Network

/// Wake-on-LAN:向局域网广播 magic packet 唤醒目标机。
/// magic packet = 6 字节 0xFF + 目标 MAC 重复 16 次,UDP 广播到 9 号端口(discard)。
enum WakeOnLAN {
    enum WakeError: LocalizedError {
        case invalidMAC

        var errorDescription: String? {
            switch self {
            case .invalidMAC: return String(localized: "MAC 地址格式不正确(应为 6 组十六进制,如 AA:BB:CC:11:22:33)。")
            }
        }
    }

    /// 解析 MAC 字符串为 6 字节;支持 `:`/`-`/无分隔与大小写
    static func parseMAC(_ raw: String) -> [UInt8]? {
        let hex = raw.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// 构造 magic packet(102 字节)
    static func magicPacket(for mac: [UInt8]) -> Data {
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac) }
        return data
    }

    /// 广播唤醒。默认发到 255.255.255.255,同时可带子网定向广播地址(如 192.168.1.255)。
    static func wake(mac rawMAC: String, broadcasts: [String] = ["255.255.255.255"], ports: [UInt16] = [9, 7]) throws {
        guard let mac = parseMAC(rawMAC) else { throw WakeError.invalidMAC }
        let packet = magicPacket(for: mac)
        for host in broadcasts {
            for port in ports {
                send(packet, to: host, port: port)
            }
        }
    }

    /// 从主机名/IP 推导子网定向广播地址(仅对形如 a.b.c.d 的 IPv4 生效)
    static func subnetBroadcast(for hostname: String) -> String? {
        let parts = hostname.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    private static func send(_ packet: Data, to host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // 允许广播
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
        let queue = DispatchQueue(label: "berth.wol")
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        // 兜底关闭
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }
}
