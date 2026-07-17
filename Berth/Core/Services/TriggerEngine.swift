import Foundation
import SwiftData

/// 触发器引擎:持有已启用触发器的编译正则,对终端输出逐行匹配,命中发通知。
/// 数据变更由 UI 调用 reload();各触发器命中有 3 秒节流。
@MainActor
final class TriggerEngine {
    static let shared = TriggerEngine()

    private struct Compiled {
        let id: UUID
        let name: String
        let regex: NSRegularExpression
        let playSound: Bool
    }

    private var compiled: [Compiled] = []
    private var container: ModelContainer?
    private var lastFired: [UUID: Date] = [:]
    private let throttle: TimeInterval = 3

    /// ANSI/OSC 转义序列剥离(匹配纯文本,避免颜色码干扰)
    private static let ansi = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}]"
    )

    var hasEnabledTriggers: Bool { !compiled.isEmpty }

    func start(container: ModelContainer) {
        self.container = container
        reload()
    }

    /// 触发器增删改后调用:重新编译启用项
    func reload() {
        guard let container else { return }
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Trigger>())) ?? []
        compiled = all.compactMap { trigger in
            guard trigger.isEnabled, !trigger.pattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: trigger.pattern, options: [.caseInsensitive])
            else { return nil }
            return Compiled(id: trigger.id, name: trigger.name, regex: regex, playSound: trigger.playSound)
        }
    }

    /// 对一整行输出做匹配;命中即发通知(节流)。hostLabel 用于通知正文。
    func scan(line rawLine: String, hostLabel: String, now: Date = Date()) {
        guard !compiled.isEmpty else { return }
        let line = Self.strip(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let range = NSRange(line.startIndex..., in: line)
        for trigger in compiled {
            guard trigger.regex.firstMatch(in: line, options: [], range: range) != nil else { continue }
            if let last = lastFired[trigger.id], now.timeIntervalSince(last) < throttle { continue }
            lastFired[trigger.id] = now
            NotificationService.post(
                title: String(localized: "触发器命中:\(trigger.name)"),
                body: "\(hostLabel) — \(String(line.prefix(120)))"
            )
        }
    }

    private static func strip(_ text: String) -> String {
        guard let ansi else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
