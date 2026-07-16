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

    var body: some View {
        List(selection: $selection) {
            // fullSizeContentView 下内容到顶,给红绿灯让位
            Color.clear
                .frame(height: 22)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            Section {
                Label("全部主机", systemImage: "server.rack")
                    .tag(SidebarSelection.allHosts)
                if !configHosts.isEmpty {
                    Label("SSH Config", systemImage: "doc.text")
                        .tag(SidebarSelection.sshConfig)
                }
                Label("密钥", systemImage: "key")
                    .tag(SidebarSelection.keys)
            }
            Section {
                ForEach(groups) { group in
                    Label(group.name, systemImage: "folder")
                        .tag(SidebarSelection.group(group.id))
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
}
