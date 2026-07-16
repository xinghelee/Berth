import SwiftData
import SwiftUI

struct MainWindowView: View {
    @State private var sidebarSelection: SidebarSelection? = .allHosts
    @State private var quickConnect = QuickConnectController.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var quickConnect = quickConnect
        ZStack {
            NavigationSplitView {
                SidebarView(selection: $sidebarSelection)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
            } content: {
                if sidebarSelection == .keys {
                    KeysListView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
                } else {
                    HostListView(sidebarSelection: sidebarSelection)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
                }
            } detail: {
                TerminalTabsView()
            }

            if quickConnect.isPresented {
                Color.black.opacity(0.001) // 点击空白处关闭
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: quickConnect.isPresented)
        .sheet(item: $quickConnect.directConnectRequest) { request in
            DirectConnectSheet(request: request)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            SSHConfigService.shared.start(container: modelContext.container)
        }
    }
}
