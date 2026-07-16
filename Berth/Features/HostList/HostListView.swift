import SwiftData
import SwiftUI

struct HostListView: View {
    let sidebarSelection: SidebarSelection?

    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]

    @State private var searchText = ""
    @State private var selectedHostID: UUID?
    @State private var hoveredHostID: UUID?
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var hostPendingDeletion: Host?
    @State private var configHostPendingDeletion: Host?

    private var visibleHosts: [Host] {
        var hosts = allHosts
        switch sidebarSelection {
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
        VStack(spacing: 0) {
            columnHeader
            if allHosts.isEmpty {
                emptyState
            } else {
                hostList
            }
        }
        .background(ThemeStore.shared.current.panelBackground)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil, defaultGroupID: nil)
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
        .confirmationDialog(
            "从 ~/.ssh/config 删除「\(configHostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { configHostPendingDeletion != nil },
                set: { if !$0 { configHostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let host = configHostPendingDeletion {
                    SSHConfigService.shared.removeHostFromConfig(alias: host.label)
                }
                configHostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { configHostPendingDeletion = nil }
        } message: {
            Text("会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
    }

    private var columnTitle: String {
        switch sidebarSelection {
        case .sshConfig: return "SSH Config"
        default: return "全部主机"
        }
    }

    private func rowBackground(for host: Host) -> Color {
        if selectedHostID == host.id { return ThemeStore.shared.current.accentSoft }
        if hoveredHostID == host.id { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var columnHeader: some View {
        let theme = ThemeStore.shared.current
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(columnTitle)
                    .font(.headline)
                Text("\(visibleHosts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                Button {
                    isCreatingHost = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.accentSoft))
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
                .help("新建主机")
            }
            .frame(height: AppLayout.topBarHeight)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索主机", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, AppLayout.columnTopPadding)
        .padding(.bottom, 10)
    }

    private var hostList: some View {
        List(selection: $selectedHostID) {
            ForEach(visibleHosts) { host in
                HostRowView(host: host)
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(rowBackground(for: host))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .animation(.easeOut(duration: 0.12), value: hoveredHostID)
                    )
                    .tag(host.id)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        hoveredHostID = hovering ? host.id : (hoveredHostID == host.id ? nil : hoveredHostID)
                    }
                    .onDrag { NSItemProvider(object: host.id.uuidString as NSString) }
                    .onTapGesture(count: 2) {
                        connect(to: host)
                    }
                    .contextMenu {
                        Button("连接") { connect(to: host) }
                        Button("复制 IP") { copyIP(for: host) }
                        Button("复制 ssh 命令") { copySSHCommand(for: host) }
                        if !groups.isEmpty {
                            Divider()
                            Menu("移动到分组") {
                                ForEach(groups) { group in
                                    Button {
                                        host.group = group
                                    } label: {
                                        if host.group?.id == group.id {
                                            Label(group.name, systemImage: "checkmark")
                                        } else {
                                            Text(group.name)
                                        }
                                    }
                                }
                                if host.group != nil {
                                    Divider()
                                    Button("移出分组") { host.group = nil }
                                }
                            }
                        }
                        if host.source == .sshConfig {
                            Divider()
                            Button("转为托管主机…") { convertToManaged(host) }
                            Button("从 config 删除…", role: .destructive) { configHostPendingDeletion = host }
                        } else {
                            Button("编辑…") { editingHost = host }
                            Divider()
                            Button("删除…", role: .destructive) { hostPendingDeletion = host }
                        }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeStore.shared.current.panelBackground)
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
        sessionManager.open(spec: HostSpec.resolve(host, in: allHosts))
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

    private func copyIP(for host: Host) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(host.hostname, forType: .string)
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
    @Environment(SessionManager.self) private var sessionManager

    private var liveState: SessionManager.HostLiveState {
        sessionManager.liveState(for: host.id)
    }

    private var dotColor: Color {
        switch liveState {
        case .connected: return .green
        case .connecting: return .yellow
        case .none: return host.tagColor.color
        }
    }

    private var dotOpacity: Double {
        switch liveState {
        case .connected, .connecting: return 1
        case .none: return host.tagColor == .none ? 0.15 : 1
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(dotOpacity)
                .overlay {
                    // 已连主机加一圈柔光,更醒目
                    if liveState == .connected {
                        Circle().stroke(Color.green.opacity(0.35), lineWidth: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.body)
                Text(host.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let lastConnected = host.lastConnectedAt {
                Text(lastConnected.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("来自 ~/.ssh/config(只读)")
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
