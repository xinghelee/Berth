import Foundation
import Observation

/// ⌘P 全局命令面板的显隐状态
@MainActor
@Observable
final class CommandPaletteController {
    static let shared = CommandPaletteController()
    var isPresented = false
    func toggle() { isPresented.toggle() }
    func dismiss() { isPresented = false }
}

/// 一条可执行命令(动作/主题切换等)
@MainActor
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    /// 是否当前可用(如「分屏」需有活跃会话)
    var isEnabled: Bool = true
    let run: () -> Void
}
