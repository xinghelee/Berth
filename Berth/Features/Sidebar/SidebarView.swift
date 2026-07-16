import AppKit
import SwiftData
import SwiftUI

/// 侧栏(双栏布局的左栏):搜索 + 一个平铺主机列表 + 底部密钥入口。
/// 按用户要求不做分组树:所有主机(托管 + ssh_config 镜像)一列到底,
/// 两行行样式 —— 标题 + user@host 副标题;config 镜像带文档角标。
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]

    @State private var searchText = ""
    /// 键盘/单击选中的主机行
    @State private var selectedHostID: UUID?
    /// 主题配色面板(popover)
    @State private var isThemePanelPresented = false

    // 编辑/删除状态(删除只存快照,不持有模型 —— 模型可能被 config 同步等外部删除,悬空访问会崩溃)
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var hostPendingDeletion: PendingHost?
    @State private var configHostPendingDeletion: PendingHost?

    private struct PendingHost: Identifiable {
        let id: UUID
        let label: String
    }

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var visibleHosts: [Host] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allHosts }
        return allHosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if allHosts.isEmpty {
                emptyState
            } else {
                hostList
            }
            Divider().overlay(theme.borderColor)
            keysRow
        }
        .background(theme.sidebarBackground)
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
                // 按 id 重新取,模型可能已被外部删除
                if let pending = hostPendingDeletion,
                   let host = allHosts.first(where: { $0.id == pending.id }) {
                    KeychainStore.deleteSecrets(for: host.id)
                    modelContext.delete(host)
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
                if let pending = configHostPendingDeletion {
                    SSHConfigService.shared.removeHostFromConfig(alias: pending.label)
                }
                configHostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { configHostPendingDeletion = nil }
        } message: {
            Text("会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
    }

    /// 搜索框 + 新建主机
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索主机", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { connectSelectionOrFirst() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
            )

            PanelIconButton(symbol: "plus", help: "新建主机") { isCreatingHost = true }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onChange(of: searchText) { _, _ in
            if let selected = selectedHostID, !visibleHosts.contains(where: { $0.id == selected }) {
                selectedHostID = visibleHosts.first?.id
            }
        }
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if visibleHosts.isEmpty {
                    Text("没有匹配的主机")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(visibleHosts) { host in
                        HostRow(
                            host: host,
                            isSelected: selectedHostID == host.id,
                            theme: theme
                        )
                        .onTapGesture(count: 2) { connect(host) }
                        .onTapGesture { selectedHostID = host.id }
                        .contextMenu { hostMenu(host) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.return) { connectSelectionOrFirst(); return .handled }
        .onKeyPress(.deleteForward) { requestDeleteSelection(); return .handled }
        .onKeyPress(KeyEquivalent("\u{7F}")) { requestDeleteSelection(); return .handled }
    }

    @ViewBuilder
    private func hostMenu(_ host: Host) -> some View {
        Button("连接") { connect(host) }
        Button("复制 IP") { copyToPasteboard(host.hostname) }
        Button("复制 ssh 命令") { copyToPasteboard(sshCommand(for: host)) }
        Divider()
        if host.source == .sshConfig {
            Button("转为托管主机…") { convertToManaged(host) }
            Button("从 config 删除…", role: .destructive) {
                configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        } else {
            Button("编辑…") { editingHost = host }
            Button("删除…", role: .destructive) {
                hostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        }
    }

    /// 底部工具行:左「密钥」入口(独立窗口),右 主题配色 + 设置(应用级功能放左下角,macOS 惯例)
    private var keysRow: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("密钥")
                    .font(.system(size: 13))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .modifier(RowHover())
            .onTapGesture { openWindow(id: "keys") }
            .help("密钥管理(独立窗口)")

            Spacer()

            PanelIconButton(symbol: "paintpalette", help: "终端配色") { isThemePanelPresented.toggle() }
                .popover(isPresented: $isThemePanelPresented, arrowEdge: .top) {
                    ThemePanelView()
                }
            SettingsIconLink()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("还没有主机")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                isCreatingHost = true
            } label: {
                Label("新建主机", systemImage: "plus")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            Text("也可 ⌘K 粘贴 ssh 命令直连")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    private func connect(_ host: Host) {
        selectedHostID = host.id
        host.lastConnectedAt = Date()
        sessionManager.open(spec: HostSpec.resolve(host, in: allHosts))
    }

    /// 回车:有选中连选中,否则连第一个可见结果(搜索场景)
    private func connectSelectionOrFirst() {
        let rows = visibleHosts
        if let selected = selectedHostID, let host = rows.first(where: { $0.id == selected }) {
            connect(host)
        } else if !searchText.isEmpty, let first = rows.first {
            connect(first)
        }
    }

    private func moveSelection(_ delta: Int) {
        let rows = visibleHosts
        guard !rows.isEmpty else { return }
        guard let current = selectedHostID, let index = rows.firstIndex(where: { $0.id == current }) else {
            selectedHostID = delta > 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = min(max(index + delta, 0), rows.count - 1)
        selectedHostID = rows[next].id
    }

    private func requestDeleteSelection() {
        guard let selected = selectedHostID,
              let host = visibleHosts.first(where: { $0.id == selected }) else { return }
        if host.source == .sshConfig {
            configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
        } else {
            hostPendingDeletion = PendingHost(id: host.id, label: host.label)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sshCommand(for host: Host) -> String {
        var command = "ssh \(host.username)@\(host.hostname)"
        if host.port != 22 { command += " -p \(host.port)" }
        if host.authMethod == .privateKeyFile, let keyPath = host.privateKeyPath, !keyPath.isEmpty {
            command += " -i \(keyPath)"
        }
        return command
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

/// 主机行:状态点 + 标题 + user@host 副标题,config 镜像带文档角标
private struct HostRow: View {
    let host: Host
    var isSelected = false
    let theme: TerminalTheme
    @Environment(SessionManager.self) private var sessionManager

    @State private var hovering = false

    private var dotColor: Color {
        switch sessionManager.liveState(for: host.id) {
        case .connected: return .green
        case .connecting: return .yellow
        case .none: return host.tagColor == .none ? Color.gray.opacity(0.4) : host.tagColor.color
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if case .connected = sessionManager.liveState(for: host.id) {
                        Circle().stroke(Color.green.opacity(0.35), lineWidth: 2.5)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(host.address)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .help("来自 ~/.ssh/config(只读)")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.accentSoft : (hovering ? Color.primary.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("\(host.address)\(host.lastConnectedAt.map { " · 最近连接 " + $0.formatted(.relative(presentation: .named)) } ?? "")")
    }
}

/// 设置入口:SettingsLink 套 PanelIconButton 同款外观(SettingsLink 不能换成普通 Button,
/// macOS 14+ 打开设置窗口只有这一个受支持入口)
private struct SettingsIconLink: View {
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("设置(⌘,)")
    }
}

/// 通用行悬停底色
private struct RowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
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
