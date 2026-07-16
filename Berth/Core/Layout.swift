import Foundation

/// 窗口顶部各列首行的共享布局常量,保证主机列表头部与终端标签条水平对齐。
enum AppLayout {
    /// 首行(标题行 / 标签条)的高度
    static let topBarHeight: CGFloat = 30
    /// 首行距标题栏下方的留白
    static let columnTopPadding: CGFloat = 4
}
