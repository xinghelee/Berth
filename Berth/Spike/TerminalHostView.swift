import SwiftTerm
import SwiftUI

/// 把 SwiftTerm 的 NSView 包装进 SwiftUI。视图实例由 SpikeSession 持有,
/// 这样会话生命周期与 SwiftUI 视图刷新解耦。
struct TerminalHostView: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalView {
        terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
