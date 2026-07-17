import SwiftData
import SwiftUI

/// 主窗口:双栏 —— 统一树侧栏(搜索 + 主机树 + 密钥入口)| 终端区。
/// 中列已按「统一树侧栏」方案移除,主机永远只在侧栏树出现一份,终端拿到余下全宽。
struct MainWindowView: View {
    @State private var quickConnect = QuickConnectController.shared
    @State private var commandPalette = CommandPaletteController.shared
    @State private var snippetRun = SnippetRunController.shared
    @State private var theme = ThemeStore.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var quickConnect = quickConnect
        @Bindable var snippetRun = snippetRun
        ZStack {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } detail: {
                TerminalTabsView()
            }

            if quickConnect.isPresented {
                Color.black.opacity(0.28) // 点击空白处关闭 + 压暗背景聚焦
                    .contentShape(Rectangle())
                    .onTapGesture { quickConnect.dismiss() }
                VStack {
                    QuickConnectPanel()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if commandPalette.isPresented {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { commandPalette.dismiss() }
                VStack {
                    CommandPaletteView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .tint(theme.current.accentColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: quickConnect.isPresented)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: commandPalette.isPresented)
        .background(WindowConfigurator(
            appearanceName: theme.current.appearanceName,
            backgroundColor: theme.current.backgroundNSColor
        ))
        .sheet(item: $quickConnect.directConnectRequest) { request in
            DirectConnectSheet(request: request)
        }
        .sheet(item: $snippetRun.pending) { snippet in
            SnippetRunSheet(snippet: snippet)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            Persistence.dedupManualHosts(container: modelContext.container)
            SSHConfigService.shared.start(container: modelContext.container)
            TriggerEngine.shared.start(container: modelContext.container)
            theme.applyWindowChrome()
        }
    }
}
