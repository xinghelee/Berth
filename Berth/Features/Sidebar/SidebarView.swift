import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case allHosts
    case sshConfig
    case keys
}

/// 侧栏:顶部固定入口 + 分组树(分组行可展开显示其下主机)。
/// 不用 List 而用自定义行:macOS 的 List 行内 dropDestination/draggable 不可靠,
/// 且分组展开/拖放高亮/悬停反馈都需要完全自定义的视觉。
struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]

    @State private var isAddingGroup = false
    @State private var newGroupName = ""
    /// 展开的分组
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var didInitExpansion = false
    /// 主机拖到分组/全部主机上时的高亮目标
    @State private var dropTargetGroupID: UUID?
    @State private var isDropTargetAllHosts = false

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private var configHosts: [Host] { allHosts.filter { $0.source == .sshConfig } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRowLabel(
                    icon: "server.rack", title: "全部主机",
                    isSelected: selection == .allHosts,
                    isDropTarget: isDropTargetAllHosts,
                    theme: theme
                )
                .onTapGesture { selection = .allHosts }
                .onDrop(of: [.plainText], isTargeted: $isDropTargetAllHosts) { providers in
                    handleHostDrop(providers, group: nil)
                }

                if !configHosts.isEmpty {
                    SidebarRowLabel(
                        icon: "doc.text", title: "SSH Config",
                        isSelected: selection == .sshConfig,
                        theme: theme
                    )
                    .onTapGesture { selection = .sshConfig }
                }

                SidebarRowLabel(
                    icon: "key", title: "密钥",
                    isSelected: selection == .keys,
                    theme: theme
                )
                .onTapGesture { selection = .keys }

                groupsHeader
                    .padding(.top, 16)
                    .padding(.bottom, 2)

                ForEach(groups) { group in
                    groupRow(group)
                    if expandedGroupIDs.contains(group.id) {
                        ForEach(sortedHosts(of: group)) { host in
                            hostRow(host)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .background(theme.sidebarBackground)
        .onAppear {
            // 首次进入默认全部展开
            guard !didInitExpansion else { return }
            didInitExpansion = true
            expandedGroupIDs = Set(groups.map(\.id))
        }
        .onChange(of: configHosts.isEmpty) { _, isEmpty in
            // SSH Config 入口随 config 主机清空而隐藏,选中态不能卡在隐藏项上
            if isEmpty, selection == .sshConfig { selection = .allHosts }
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
    }

    private var groupsHeader: some View {
        HStack(spacing: 4) {
            Text("分组")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Button {
                isAddingGroup = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建分组")
            Spacer()
        }
        .padding(.leading, 8)
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
            Button("删除分组", role: .destructive) { modelContext.delete(group) }
        }
    }

    private func hostRow(_ host: Host) -> some View {
        SidebarHostRow(host: host, theme: theme)
            .onTapGesture(count: 2) { connect(host) }
            .contextMenu {
                Button("连接") { connect(host) }
                Button("移出分组") { host.group = nil }
            }
    }

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
        host.lastConnectedAt = Date()
        sessionManager.open(spec: HostSpec.resolve(host, in: allHosts))
    }

    /// 接收主机列表拖来的主机(UUID 字符串);group 为 nil = 移出分组
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

/// 分组下的主机行(缩进,带连接状态点),双击连接
private struct SidebarHostRow: View {
    let host: Host
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
            Text(host.label)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .padding(.leading, 34)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("双击连接 \(host.address)")
    }
}
