import Foundation

/// 从原始 PTY 字节流里解析 Shell 集成标记(FinalTerm/iTerm2 OSC 133):
///   ESC ] 133 ; A ST      提示符开始
///   ESC ] 133 ; B ST      命令输入开始
///   ESC ] 133 ; C ST      命令执行(输出开始)
///   ESC ] 133 ; D ; <code> ST   命令结束(带退出码)
/// ST = BEL(0x07)或 ESC \\。跨 chunk 的序列用内部缓冲拼接。
struct OSC133Scanner {
    enum Event {
        case promptStart      // A
        case commandStart     // B
        case outputStart      // C
        case commandEnd(Int?) // D;code
    }

    private var buffer: [UInt8] = []
    private var capturing = false

    private static let prefix: [UInt8] = [0x1b, 0x5d, 0x31, 0x33, 0x33] // ESC ] 1 3 3

    mutating func scan(_ bytes: ArraySlice<UInt8>) -> [Event] {
        var events: [Event] = []
        for b in bytes {
            if capturing {
                // 序列终止:BEL 或 ESC \\
                if b == 0x07 {
                    if let e = parse(buffer) { events.append(e) }
                    capturing = false; buffer = []
                } else if b == 0x5c, buffer.last == 0x1b {
                    buffer.removeLast()
                    if let e = parse(buffer) { events.append(e) }
                    capturing = false; buffer = []
                } else {
                    buffer.append(b)
                    if buffer.count > 64 { capturing = false; buffer = [] } // 防跑飞
                }
            } else {
                buffer.append(b)
                if buffer.count > Self.prefix.count { buffer.removeFirst(buffer.count - Self.prefix.count) }
                if buffer == Self.prefix {
                    capturing = true
                    buffer = []
                }
            }
        }
        return events
    }

    /// buffer 形如 ";A" / ";D;0" 等(前缀已去掉,首字符是 ';')
    private func parse(_ body: [UInt8]) -> Event? {
        guard let s = String(bytes: body, encoding: .utf8) else { return nil }
        let parts = s.split(separator: ";", omittingEmptySubsequences: true).map(String.init)
        guard let kind = parts.first else { return nil }
        switch kind {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .outputStart
        case "D":
            let code = parts.count > 1 ? Int(parts[1]) : nil
            return .commandEnd(code)
        default: return nil
        }
    }
}
