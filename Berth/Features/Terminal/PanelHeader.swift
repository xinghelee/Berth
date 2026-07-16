import SwiftUI

/// 终端右侧面板(SFTP 文件 / 服务器信息)的统一头部:紧凑标题 + 图标按钮排。
/// 面板位于标签条下方,不需要窗口顶栏那套 AppLayout 留白。
struct PanelHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            actions
        }
        .frame(height: 34)
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}

/// 面板头部图标按钮:统一 24pt 命中区、12pt 图标、悬停底色。
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    /// 激活态颜色(如面板开关的选中态);nil 时用次要色
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                    value: spinning
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}
