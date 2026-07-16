import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 统一树侧栏(双栏布局的左栏):搜索 + 主机树 + 底部密钥入口。
/// 主机永远只在这棵树里出现一份:未分组主机顶层平铺,分组可展开,
/// SSH Config 是置底只读分组;搜索时平铺全库结果并在行尾标注所属分组。
/// 不用 List 而用自定义行:macOS 的 List 行内拖放不可靠,且需要完全自定义的视觉。
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]

    @State private var searchText = ""
    /// 键盘/单击选中的主机行
    @State private var selectedHostID: UUID?
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isConfigGroupExpanded = true
    @State private var didInitExpansion = false
    /// 拖放目标高亮
    @State private var dropTargetGroupID: UUID?
    @State private var isDropTargetConfig = false
    @State private var isDropTargetBackground = false

    // 编辑/删除状态(删除只存快照,不持有模型 —— 模型可能被 config 同步等外部删除,悬空访问会崩溃)
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var isAddingGroup = false
    @State private var newGroupName = ""
    @State private var hostPendingDeletion: PendingHost?
    @State private var configHostPendingDeletion: PendingHost?

    private struct PendingHost: Identifiable {
        let id: UUID
        let label: String
    }

    private var theme: TerminalTheme { ThemeStore.shared.current }

    // MARK: - 数据切片

    /// 未分组的托管主机(config 镜像主机在置底的 SSH Config 组)
    private var ungroupedHosts: [Host] {
        allHosts.filter { $0.group == nil && $0.source != .sshConfig }
    }

    private var configHosts: [Host] {
        allHosts.filter { $0.source == .sshConfig && $0.group == nil }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchResults: [Host] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return allHosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    /// 当前可见主机行(按展示顺序),键盘 ↑↓ 在其中移动
    private var visibleHosts: [Host] {
        if isSearching { return searchResults }
        var rows = ungroupedHosts
        for group in groups where expandedGroupIDs.contains(group.id) {
            rows += sortedHosts(of: group)
        }
        if isConfigGroupExpanded { rows += configHosts }
        return rows
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            header
            if allHosts.isEmpty {
                emptyState
            } else {
                tree
            }
            Divider().overlay(theme.borderColor)
            keysRow
        }
        .background(theme.sidebarBackground)
        .onAppear {
            guard !didInitExpansion else { return }
            didInitExpansion = true
            expandedGroupIDs = Set(groups.map(\.id))
        }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil, defaultGroupID: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil)
        }
        .alert("新建分组", isPresented: $isAddingGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let group = HostGroup(name: name, sortOrder: (groups.last?.sortOrder ?? 0) + 1)
                modelContext.insert(group)
                expandedGroupIDs.insert(group.id)
                newGroupName = ""
            }
            Button("取消", role: .cancel) { newGroupName = "" }
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

    /// 搜索框 + 新建菜单
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

            AddMenu(theme: theme) {
                isCreatingHost = true
            } addGroup: {
                isAddingGroup = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onChange(of: searchText) { _, _ in
            // 切换搜索/树模式时选中态跟随可见集,避免残留在不可见行上
            if let selected = selectedHostID, !visibleHosts.contains(where: { $0.id == selected }) {
                selectedHostID = visibleHosts.first?.id
            }
        }
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if isSearching {
                    searchList
                } else {
                    treeRows
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: $isDropTargetBackground) { providers in
            // 拖到树空白处 = 移出分组
            handleHostDrop(providers, group: nil)
        }
        .overlay(alignment: .bottom) {
            if isDropTargetBackground {
                Text("松手移出分组")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.elevatedBackground))
                    .padding(.bottom, 6)
            }
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
    private var treeRows: some View {
        // 未分组主机顶层平铺
        ForEach(ungroupedHosts) { host in
            hostRow(host, indented: false)
        }

        // 用户分组
        ForEach(groups) { group in
            groupRow(group)
            if expandedGroupIDs.contains(group.id) {
                let members = sortedHosts(of: group)
                if members.isEmpty {
                    Text("空分组,把主机拖进来")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 34)
                        .padding(.vertical, 3)
                } else {
                    ForEach(members) { host in
                        hostRow(host, indented: true)
                    }
                }
            }
        }

        // SSH Config 只读分组(有内容才显示)
        if !configHosts.isEmpty {
            configGroupRow
            if isConfigGroupExpanded {
                ForEach(configHosts) { host in
                    hostRow(host, indented: true)
                }
            }
        }
    }

    @ViewBuilder
    private var searchList: some View {
        if searchResults.isEmpty {
            Text("没有匹配的主机")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            ForEach(searchResults) { host in
                hostRow(host, indented: false, groupTag: groupTag(for: host))
            }
        }
    }

    private func groupTag(for host: Host) -> String? {
        if host.source == .sshConfig, host.group == nil { return "config" }
        return host.group?.name
    }

    private func groupRow(_ group: HostGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        return SidebarRowLabel(
            icon: "folder", title: group.name,
            chevronExpanded: isExpanded,
            trailingCount: group.hosts.count,
            isDropTarget: dropTargetGroupID == group.id,
            theme: theme
        )
        .help(group.name)
        .onTapGesture { toggleExpansion(group) }
        .onDrop(
            of: [.plainText],
            isTargeted: Binding(
                get: { dropTargetGroupID == group.id },
                set: { targeting in
                    dropTargetGroupID = targeting ? group.id : (dropTargetGroupID == group.id ? nil : dropTargetGroupID)
                }
            )
        ) { providers in
            handleHostDrop(providers, group: group)
        }
        .contextMenu {
            Button(isExpanded ? "收起" : "展开") { toggleExpansion(group) }
            Divider()
            Button("删除分组", role: .destructive) {
                expandedGroupIDs.remove(group.id)
                modelContext.delete(group)
            }
        }
    }

    private var configGroupRow: some View {
        SidebarRowLabel(
            icon: "doc.text", title: "SSH Config",
            chevronExpanded: isConfigGroupExpanded,
            trailingCount: configHosts.count,
            theme: theme
        )
        .help("~/.ssh/config 镜像(只读,自动同步)")
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { isConfigGroupExpanded.toggle() }
        }
    }

    private func hostRow(_ host: Host, indented: Bool, groupTag: String? = nil) -> some View {
        HostTreeRow(
            host: host,
            indented: indented,
            groupTag: groupTag,
            isSelected: selectedHostID == host.id,
            theme: theme
        )
        .onTapGesture(count: 2) { connect(host) }
        .onTapGesture { selectedHostID = host.id }
        .onDrag { NSItemProvider(object: host.id.uuidString as NSString) }
        .contextMenu { hostMenu(host) }
    }

    @ViewBuilder
    private func hostMenu(_ host: Host) -> some View {
        Button("连接") { connect(host) }
        Button("复制 IP") { copyToPasteboard(host.hostname) }
        Button("复制 ssh 命令") { copyToPasteboard(sshCommand(for: host)) }
        if !groups.isEmpty {
            Divider()
            Menu("移动到分组") {
                ForEach(groups) { group in
                    Button {
                        host.group = group
                        expandedGroupIDs.insert(group.id)
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

    /// 底部固定「密钥」入口 → 独立窗口(不与终端争空间)
    private var keysRow: some View {
        SidebarRowLabel(icon: "key", title: "密钥", theme: theme)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .onTapGesture { openWindow(id: "keys") }
            .help("密钥管理(独立窗口)")
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

    private func sortedHosts(of group: HostGroup) -> [Host] {
        group.hosts.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private func toggleExpansion(_ group: HostGroup) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedGroupIDs.contains(group.id) {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

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
        } else if isSearching, let first = rows.first {
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

    /// 接收拖来的主机(UUID 字符串);group 为 nil = 移出分组
    private func handleHostDrop(_ providers: [NSItemProvider], group: HostGroup?) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let idString = string as? String, let id = UUID(uuidString: idString) else { return }
                Task { @MainActor in
                    var descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    guard let host = try? modelContext.fetch(descriptor).first else { return }
                    host.group = group
                    if let group {
                        withAnimation(.easeOut(duration: 0.15)) {
                            _ = expandedGroupIDs.insert(group.id)
                        }
                    }
                }
            }
        }
        return handled
    }
}

/// 「+」菜单:新建主机 / 新建分组,带悬停反馈
private struct AddMenu: View {
    let theme: TerminalTheme
    let addHost: () -> Void
    let addGroup: () -> Void

    @State private var hovering = false

    var body: some View {
        Menu {
            Button("新建主机…", action: addHost)
            Button("新建分组…", action: addGroup)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("新建主机 / 分组")
    }
}

/// 侧栏通用行:图标 + 标题,支持选中态/悬停/拖放高亮/展开箭头/尾部计数
private struct SidebarRowLabel: View {
    let icon: String
    let title: String
    var chevronExpanded: Bool?
    var trailingCount: Int?
    var isSelected = false
    var isDropTarget = false
    let theme: TerminalTheme

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let chevronExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chevronExpanded ? 90 : 0))
                    .frame(width: 10)
            }
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? theme.accentColor : .secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailingCount, trailingCount > 0 {
                Text("\(trailingCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(background)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isDropTarget {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentSoft)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentColor.opacity(0.6), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.accentSoft : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
    }
}

/// 树中的主机行:状态点 + 名称(+ 搜索态的分组标签),地址进 tooltip
private struct HostTreeRow: View {
    let host: Host
    let indented: Bool
    var groupTag: String?
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
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .overlay {
                    if case .connected = sessionManager.liveState(for: host.id) {
                        Circle().stroke(Color.green.opacity(0.35), lineWidth: 2.5)
                    }
                }
            Text(host.label)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let groupTag {
                Text(groupTag)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            } else if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, indented ? 34 : 10)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.accentSoft : (hovering ? Color.primary.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("\(host.address)\(host.lastConnectedAt.map { " · 最近连接 " + $0.formatted(.relative(presentation: .named)) } ?? "")")
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
