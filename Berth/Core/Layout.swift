import Foundation

/// 窗口顶部各列首行的共享布局常量,保证主机列表头部与终端标签条水平对齐。
enum AppLayout {
    /// 首行(标题行 / 标签条)的高度
    static let topBarHeight: CGFloat = 30
    /// 首行距窗口顶端的留白(fullSizeContentView 下内容到顶,这里给红绿灯下方留一点)
    static let columnTopPadding: CGFloat = 10
}
