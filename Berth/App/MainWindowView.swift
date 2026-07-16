import SwiftData
import SwiftUI

struct MainWindowView: View {
    @State private var sidebarSelection: SidebarSelection? = .allHosts
    @State private var quickConnect = QuickConnectController.shared
    @State private var theme = ThemeStore.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var quickConnect = quickConnect
        ZStack {
            NavigationSplitView {
                SidebarView(selection: $sidebarSelection)
                    .navigationSplitViewColumnWidth(min: 168, ideal: 196, max: 260)
            } content: {
                if sidebarSelection == .keys {
                    KeysListView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
                } else {
                    HostListView(sidebarSelection: sidebarSelection)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
                }
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
        }
        .tint(theme.current.accentColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: quickConnect.isPresented)
        .background(WindowConfigurator(
            appearanceName: theme.current.appearanceName,
            backgroundColor: theme.current.backgroundNSColor
        ))
        .sheet(item: $quickConnect.directConnectRequest) { request in
            DirectConnectSheet(request: request)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            SSHConfigService.shared.start(container: modelContext.container)
            theme.applyWindowChrome()
        }
    }
}

/// 抓到承载视图的 NSWindow,套用主题外观并把标题栏并入内容区,得到统一的深色边到边观感。
/// backgroundColor 钉死为主题底色:macOS 深色模式默认会把壁纸颜色渗进窗口材质(desktop tinting),
/// 与主题冷色底冲突,表现为顶部/空白区一条不搭的暖灰。
private struct WindowConfigurator: NSViewRepresentable {
    let appearanceName: NSAppearance.Name
    let backgroundColor: NSColor

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
        window.titleVisibility = .hidden
        window.backgroundColor = backgroundColor
    }
}
