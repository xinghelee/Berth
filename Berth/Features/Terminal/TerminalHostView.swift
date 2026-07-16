import SwiftTerm
import SwiftUI

/// 把 SwiftTerm 的 NSView 包装进 SwiftUI。视图实例由 TerminalSession 持有,
/// 会话生命周期与 SwiftUI 视图刷新解耦,标签切换不丢 scrollback。
struct TerminalHostView: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalView {
        terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
