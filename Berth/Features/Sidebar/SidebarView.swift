import SwiftData
import SwiftUI

enum SidebarSelection: Hashable {
    case allHosts
    case group(UUID)
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]

    @State private var isAddingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("全部主机", systemImage: "server.rack")
                    .tag(SidebarSelection.allHosts)
            }
            Section("分组") {
                ForEach(groups) { group in
                    Label(group.name, systemImage: "folder")
                        .tag(SidebarSelection.group(group.id))
                        .contextMenu {
                            Button("删除分组", role: .destructive) {
                                deleteGroup(group)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    isAddingGroup = true
                } label: {
                    Label("新建分组", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .padding(8)
                Spacer()
            }
        }
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
