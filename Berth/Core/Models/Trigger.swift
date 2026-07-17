import Foundation
import SwiftData

/// 输出触发器:终端某行输出匹配正则时,发系统通知(可选响铃)。
/// 全局生效于所有会话;匹配同一触发器有节流,避免刷屏。
@Model
final class Trigger {
    @Attribute(.unique) var id: UUID
    var name: String
    /// 正则表达式(NSRegularExpression 语法)
    var pattern: String
    var isEnabled: Bool
    /// 命中时是否附带系统响铃声
    var playSound: Bool
    var sortOrder: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        isEnabled: Bool = true,
        playSound: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.playSound = playSound
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}
