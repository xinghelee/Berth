import AppKit
import SwiftUI

/// 抓到承载视图的 NSWindow,套用主题外观并把标题栏并入内容区,得到统一的深色边到边观感。
/// backgroundColor 钉死为主题底色:macOS 深色模式默认会把壁纸颜色渗进窗口材质(desktop tinting),
/// 与主题冷色底冲突,表现为顶部/空白区一条不搭的暖灰。主窗口与独立窗口(密钥)共用。
struct WindowConfigurator: NSViewRepresentable {
    let appearanceName: NSAppearance.Name
    let backgroundColor: NSColor
    /// 独立小窗(密钥)保留标题文字,主窗口隐藏
    var keepsTitle = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.appearance = NSAppearance(named: appearanceName)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = keepsTitle ? .visible : .hidden
        window.backgroundColor = backgroundColor
    }
}
