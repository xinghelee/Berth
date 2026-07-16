import Foundation
import SwiftData

/// 命令片段:一键发送到当前终端。支持 {{变量}} 占位(发送前提示填值)。
@Model
final class Snippet {
    @Attribute(.unique) var id: UUID
    var title: String
    var command: String
    var note: String
    var sortOrder: Int
    var createdAt: Date
    /// 使用次数(用于排序常用)
    var useCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        note: String = "",
        sortOrder: Int = 0,
        useCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.note = note
        self.sortOrder = sortOrder
        self.useCount = useCount
        self.createdAt = Date()
    }

    private static let varRegex = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_\\-]+)\\s*\\}\\}")

    /// 命令里的 {{变量}} 名(去重,按出现顺序)
    var variables: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let ns = command as NSString
        for m in Self.varRegex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// 用给定变量值渲染最终命令
    func render(with values: [String: String]) -> String {
        var result = command
        let ns = command as NSString
        let matches = Self.varRegex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        // 从后往前替换,避免 range 偏移
        for m in matches.reversed() {
            let name = ns.substring(with: m.range(at: 1))
            let value = values[name] ?? ""
            result = (result as NSString).replacingCharacters(in: m.range, with: value)
        }
        return result
    }
}
