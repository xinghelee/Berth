import SwiftData
import SwiftUI

enum SidebarSelection: Hashable {
    case allHosts
    case sshConfig
    case keys
    case group(UUID)
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @Query(filter: #Predicate<Host> { $0.sourceRaw == "sshConfig" }) private var configHosts: [Host]

    @State private var isAddingGroup = false
    @State private var newGroupName = ""
    /// 主机行拖到某分组上时高亮该分组
    @State private var dropTargetGroupID: UUID?
    @State private var isDropTargetAllHosts = false
    /// 鼠标悬停的行
    @State private var hoveredItem: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("全部主机", systemImage: "server.rack")
                    .tag(SidebarSelection.allHosts)
                    .listRowBackground(rowBackground(for: .allHosts, dropActive: isDropTargetAllHosts))
                    .onHover { hover(.allHosts, $0) }
                    .dropDestination(for: String.self) { items, _ in
                        assign(hostIDStrings: items, to: nil)
                    } isTargeted: { targeting in
                        isDropTargetAllHosts = targeting
                    }
                if !configHosts.isEmpty {
                    Label("SSH Config", systemImage: "doc.text")
                        .tag(SidebarSelection.sshConfig)
                        .listRowBackground(rowBackground(for: .sshConfig, dropActive: false))
                        .onHover { hover(.sshConfig, $0) }
                }
                Label("密钥", systemImage: "key")
                    .tag(SidebarSelection.keys)
                    .listRowBackground(rowBackground(for: .keys, dropActive: false))
                    .onHover { hover(.keys, $0) }
            }
            Section {
                ForEach(groups) { group in
                    Label(group.name, systemImage: "folder")
                        .tag(SidebarSelection.group(group.id))
                        .listRowBackground(rowBackground(for: .group(group.id), dropActive: dropTargetGroupID == group.id))
                        .onHover { hover(.group(group.id), $0) }
                        .dropDestination(for: String.self) { items, _ in
                            assign(hostIDStrings: items, to: group)
                        } isTargeted: { targeting in
                            dropTargetGroupID = targeting ? group.id : (dropTargetGroupID == group.id ? nil : dropTargetGroupID)
                        }
                        .contextMenu {
                            Button("删除分组", role: .destructive) {
                                deleteGroup(group)
                            }
                        }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("分组")
                    Button {
                        isAddingGroup = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建分组")
                    Spacer()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ThemeStore.shared.current.sidebarBackground)
        .alert("新建分组", isPresented: $isAddingGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let group = HostGroup(name: name, sortOrder: (groups.last?.sortOrder ?? 0) + 1)
                modelContext.insert(group)
                newGroupName = ""
            }
            Button("取消", role: .cancel) { newGroupName = "" }
        }
    }

    private func deleteGroup(_ group: HostGroup) {
        if case .group(let id) = selection, id == group.id {
            selection = .allHosts
        }
        modelContext.delete(group)
    }

    private func hover(_ item: SidebarSelection, _ hovering: Bool) {
        hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
    }

    /// 行底色:拖拽悬停(强调框)> 鼠标悬停(浅底)> 透明。选中态由 List 原生绘制。
    @ViewBuilder
    private func rowBackground(for item: SidebarSelection, dropActive: Bool) -> some View {
        if dropActive {
            RoundedRectangle(cornerRadius: 6)
                .fill(ThemeStore.shared.current.accentSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ThemeStore.shared.current.accentColor.opacity(0.6), lineWidth: 1)
                )
        } else if hoveredItem == item, selection != item {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        } else {
            Color.clear
        }
    }

    /// 把拖入的主机(UUID 字符串)归入分组;group 为 nil 表示移出分组
    private func assign(hostIDStrings: [String], to group: HostGroup?) -> Bool {
        let ids = hostIDStrings.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return false }
        var moved = false
        for id in ids {
            var descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let host = try? modelContext.fetch(descriptor).first {
                host.group = group
                moved = true
            }
        }
        return moved
    }
}
