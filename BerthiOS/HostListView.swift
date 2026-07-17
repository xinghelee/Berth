import SwiftData
import SwiftUI

/// iOS 主界面:主机列表(按分组)+ 快速连接 / 密钥 / 片段 / 设置入口。
struct HostListView: View {
    @Query(sort: \Host.sortOrder) private var hosts: [Host]
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @Environment(\.modelContext) private var modelContext
    @State private var theme = ThemeStore.shared

    @State private var editingHost: Host?
    @State private var isCreating = false
    @State private var showQuickConnect = false
    @State private var showKeys = false
    @State private var showSnippets = false
    @State private var showSettings = false
    @State private var quickSpec: QuickConnectRequest?

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle("Berth")
            .navigationDestination(for: UUID.self) { hostID in
                if let host = hosts.first(where: { $0.id == hostID }) {
                    TerminalScreen(spec: HostSpec.resolve(host, in: hosts), transientPassword: nil)
                }
            }
            .navigationDestination(item: $quickSpec) { request in
                TerminalScreen(spec: request.spec, transientPassword: request.password)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showQuickConnect = true } label: { Image(systemName: "bolt") }
                    Button { isCreating = true } label: { Image(systemName: "plus") }
                    Menu {
                        Button { showKeys = true } label: { Label(String(localized: "密钥"), systemImage: "key") }
                        Button { showSnippets = true } label: { Label(String(localized: "命令片段"), systemImage: "text.badge.plus") }
                        Button { showSettings = true } label: { Label(String(localized: "设置"), systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isCreating) { HostEditorIOS(host: nil) }
            .sheet(item: $editingHost) { host in HostEditorIOS(host: host) }
            .sheet(isPresented: $showQuickConnect) {
                QuickConnectSheet { request in
                    quickSpec = request
                }
            }
            .sheet(isPresented: $showKeys) { KeysListViewIOS() }
            .sheet(isPresented: $showSnippets) { SnippetsViewIOS(insertHandler: nil) }
            .sheet(isPresented: $showSettings) { IOSSettingsView() }
        }
    }

    // MARK: - 列表

    private var hostList: some View {
        List {
            ForEach(groupedSections, id: \.title) { section in
                Section {
                    ForEach(section.hosts) { host in
                        NavigationLink(value: host.id) {
                            hostRow(host)
                        }
                        .listRowBackground(theme.current.panelBackground)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(host)
                            } label: {
                                Label(String(localized: "删除"), systemImage: "trash")
                            }
                            Button {
                                editingHost = host
                            } label: {
                                Label(String(localized: "编辑…"), systemImage: "pencil")
                            }
                        }
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title).foregroundStyle(theme.current.secondaryText)
                    }
                }
            }
        }
    }

    private struct HostSection {
        let title: String
        let hosts: [Host]
    }

    private var groupedSections: [HostSection] {
        var sections: [HostSection] = []
        for group in groups {
            let members = hosts.filter { $0.group?.id == group.id }
            if !members.isEmpty {
                sections.append(HostSection(title: group.name, hosts: members))
            }
        }
        let ungrouped = hosts.filter { $0.group == nil }
        if !ungrouped.isEmpty {
            sections.append(HostSection(title: sections.isEmpty ? "" : String(localized: "无分组"), hosts: ungrouped))
        }
        return sections
    }

    private func hostRow(_ host: Host) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tagColor(host))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.label)
                        .fontWeight(.medium)
                    if host.isProduction {
                        Text(String(localized: "生产环境"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.18), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Text("\(host.username)@\(host.hostname):\(String(host.port))")
                    .font(.caption)
                    .foregroundStyle(theme.current.secondaryText)
                    .monospaced()
            }
        }
        .padding(.vertical, 2)
    }

    private func tagColor(_ host: Host) -> Color {
        switch host.tagColor {
        case .none: return .gray.opacity(0.5)
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "还没有主机"), systemImage: "server.rack")
        } description: {
            Text(String(localized: "点右上角 + 新建主机,或 ⚡ 快速连接"))
        } actions: {
            Button(String(localized: "新建主机")) { isCreating = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func delete(_ host: Host) {
        KeychainStore.deleteSecrets(for: host.id)
        modelContext.delete(host)
    }
}

/// 快速连接请求:临时 spec + 当场输入的密码
struct QuickConnectRequest: Identifiable, Hashable {
    let id = UUID()
    let spec: HostSpec
    let password: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
