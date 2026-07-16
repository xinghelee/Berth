import SwiftUI

/// 主题配色面板(侧栏顶部主题按钮的 popover):
/// 内置主题以色卡网格展示 —— 底色 + 前景字样 + ANSI 色点,点卡片即时切换全局配色。
struct ThemePanelView: View {
    @State private var themeStore = ThemeStore.shared

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("终端配色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(TerminalTheme.builtIn) { theme in
                        ThemeCard(theme: theme, isSelected: themeStore.current.id == theme.id)
                            .onTapGesture { themeStore.select(id: theme.id) }
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 440)
            Text("对所有已打开的终端即时生效")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 312)
    }
}

/// 单个主题色卡:迷你终端预览(底色 + Aa 字样 + ANSI 八色点)+ 名称
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: theme.backgroundNSColor))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("Aa")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(nsColor: theme.foregroundNSColor))
                        Text(">_")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(nsColor: NSColor(hex: theme.accent)))
                    }
                    HStack(spacing: 3) {
                        // ANSI 前 8 色跳过黑色位,取 1-6(红绿黄蓝品青)最能代表配色气质
                        ForEach(1..<7, id: \.self) { index in
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: theme.ansi[index])))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected
                            ? theme.accentColor
                            : (hovering ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )

            HStack(spacing: 4) {
                Text(theme.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.accentColor)
                }
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
