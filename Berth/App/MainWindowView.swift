import SwiftData
import SwiftUI

struct MainWindowView: View {
    @State private var sidebarSelection: SidebarSelection? = .allHosts

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } content: {
            HostListView(sidebarSelection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            TerminalTabsView()
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
