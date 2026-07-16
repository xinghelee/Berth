import SwiftData
import SwiftUI

struct HostListView: View {
    let sidebarSelection: SidebarSelection?

    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]

    @State private var searchText = ""
    @State private var selectedHostID: UUID?
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var hostPendingDeletion: Host?

    private var visibleHosts: [Host] {
        var hosts = allHosts
        switch sidebarSelection {
        case .group(let groupID):
            hosts = hosts.filter { $0.group?.id == groupID }
        case .sshConfig:
            hosts = hosts.filter { $0.source == .sshConfig }
        case .allHosts, .keys, nil:
            break
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hosts }
        return hosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if allHosts.isEmpty {
                emptyState
            } else {
                hostList
            }
        }
        .navigationTitle("主机")
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索主机")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingHost = true
                } label: {
                    Label("新建主机", systemImage: "plus")
                }
                .help("新建主机")
            }
        }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil, defaultGroupID: currentGroupID)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil)
        }
        .confirmationDialog(
            "删除主机「\(hostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let host = hostPendingDeletion {
                    deleteHost(host)
                }
                hostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { hostPendingDeletion = nil }
        } message: {
            Text("Keychain 中保存的凭据会一并删除,此操作不可撤销。")
        }
    }

    private var currentGroupID: UUID? {
        if case .group(let id) = sidebarSelection { return id }
        return nil
    }

    private var hostList: some View {
        List(selection: $selectedHostID) {
            ForEach(visibleHosts) { host in
                HostRowView(host: host)
                    .tag(host.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        connect(to: host)
                    }
                    .contextMenu {
                        Button("连接") { connect(to: host) }
                        Button("复制 ssh 命令") { copySSHCommand(for: host) }
                        if host.source == .sshConfig {
                            Divider()
                            Button("转为托管主机…") { convertToManaged(host) }
                        } else {
                            Button("编辑…") { editingHost = host }
                            Divider()
                            Button("删除…", role: .destructive) { hostPendingDeletion = host }
                        }
                    }
            }
        }
        .onKeyPress(.return) {
            if let id = selectedHostID, let host = visibleHosts.first(where: { $0.id == id }) {
                connect(to: host)
                return .handled
            }
            return .ignored
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有主机")
                .font(.title3)
            Button {
                isCreatingHost = true
            } label: {
                Label("新建主机", systemImage: "plus")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("导入 ~/.ssh/config 将在下个版本提供")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect(to host: Host) {
        host.lastConnectedAt = Date()
        sessionManager.open(spec: HostSpec(host: host))
    }

    private func copySSHCommand(for host: Host) {
        var command = "ssh \(host.username)@\(host.hostname)"
        if host.port != 22 { command += " -p \(host.port)" }
        if host.authMethod == .privateKeyFile, let keyPath = host.privateKeyPath, !keyPath.isEmpty {
            command += " -i \(keyPath)"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    private func deleteHost(_ host: Host) {
        KeychainStore.deleteSecrets(for: host.id)
        modelContext.delete(host)
    }

    /// ssh_config 镜像主机 → 可编辑的托管副本
    private func convertToManaged(_ host: Host) {
        let copy = Host(
            label: host.label,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            privateKeyPath: host.privateKeyPath,
            note: host.note
        )
        modelContext.insert(copy)
        editingHost = copy
    }
}

struct HostRowView: View {
    let host: Host

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(host.tagColor.color)
                .frame(width: 8, height: 8)
                .opacity(host.tagColor == .none ? 0.15 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.body)
                Text(host.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("来自 ~/.ssh/config(只读)")
            }
            if let lastConnected = host.lastConnectedAt {
                Text(lastConnected.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

extension TagColor {
    var color: Color {
        switch self {
        case .none: return .gray
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
