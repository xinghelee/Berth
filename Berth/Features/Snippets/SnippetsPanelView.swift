import SwiftData
import SwiftUI

/// 右侧片段面板(与信息面板同构):列表按使用次数排序,点击即发送到当前终端;
/// 含 {{变量}} 的片段走 SnippetRunController 弹填值表单。
struct SnippetsPanelView: View {
    let onClose: () -> Void

    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: [SortDescriptor(\Snippet.useCount, order: .reverse), SortDescriptor(\Snippet.title)])
    private var snippets: [Snippet]

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: String(localized: "命令片段")) {
                PanelIconButton(symbol: "square.and.pencil", help: String(localized: "管理命令片段")) {
                    openWindow(id: "snippets")
                }
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) { onClose() }
            }
            Divider().overlay(theme.borderColor)
            if snippets.isEmpty {
                emptyState
            } else {
                snippetList
            }
        }
        .frame(width: 260)
        .background(theme.panelBackground)
    }

    private var snippetList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(snippets) { snippet in
                    SnippetPanelRow(snippet: snippet) {
                        SnippetRunController.shared.run(snippet, in: sessionManager)
                    }
                }
            }
            .padding(6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "curlybraces")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(String(localized: "还没有片段"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "新建片段")) { openWindow(id: "snippets") }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 单行片段:标题 + 命令预览,悬停高亮,点击发送
private struct SnippetPanelRow: View {
    let snippet: Snippet
    let action: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snippet.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if hovering {
                        Image(systemName: "return")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.accentColor)
                    }
                }
                Text(snippet.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? theme.accentSoft : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(snippet.command)
    }
}
