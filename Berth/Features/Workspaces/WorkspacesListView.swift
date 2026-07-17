import SwiftData
import SwiftUI

/// 会话模板管理(独立窗口):保存当前布局为模板,一键打开 / 删除。
struct WorkspacesListView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.sortOrder) private var workspaces: [Workspace]
    @Query(sort: \Host.sortOrder) private var hosts: [Host]

    @State private var theme = ThemeStore.shared
    @State private var isNaming = false
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话模板")
                    .font(.headline)
                Spacer()
                Button {
                    newName = ""
                    isNaming = true
                } label: {
                    Label("保存当前布局", systemImage: "plus.square.on.square")
                }
                .disabled(sessionManager.tabs.isEmpty)
                .help(sessionManager.tabs.isEmpty ? String(localized: "先打开至少一个会话") : String(localized: "把当前所有标签和分屏保存为模板"))
            }
            .padding(12)

            Divider()

            if workspaces.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(workspaces) { workspace in
                        row(workspace)
                            .listRowBackground(theme.current.panelBackground)
                    }
                }
                .scrollContentBackground(.hidden)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .background(theme.current.panelBackground)
        .tint(theme.current.accentColor)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 320, idealHeight: 420)
        .alert("保存当前布局", isPresented: $isNaming) {
            TextField("模板名称", text: $newName)
            Button("保存") { saveCurrent() }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text("记录当前所有标签页与分屏结构,打开模板时按原布局重新连接。")
        }
    }

    private func row(_ workspace: Workspace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(theme.current.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .fontWeight(.medium)
                Text(summary(workspace))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") { openWorkspace(workspace) }
                .controlSize(.small)
            Button {
                modelContext.delete(workspace)
                try? modelContext.save()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除")
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有会话模板")
                .foregroundStyle(.secondary)
            Text("摆好标签和分屏后,点右上角「保存当前布局」")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ workspace: Workspace) -> String {
        guard let layout = WorkspaceLayout.decode(workspace.layoutJSON) else { return "" }
        return String(localized: "\(layout.tabs.count) 个标签页 · \(layout.hostCount) 个会话")
    }

    private func saveCurrent() {
        let layout = sessionManager.captureWorkspaceLayout()
        guard !layout.tabs.isEmpty else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let workspace = Workspace(
            name: name.isEmpty ? String(localized: "未命名模板") : name,
            layoutJSON: layout.encodedJSON(),
            sortOrder: (workspaces.map(\.sortOrder).max() ?? 0) + 1
        )
        modelContext.insert(workspace)
        try? modelContext.save()
        message = String(localized: "已保存「\(workspace.name)」")
    }

    private func openWorkspace(_ workspace: Workspace) {
        guard let layout = WorkspaceLayout.decode(workspace.layoutJSON) else { return }
        NSApp.activate(ignoringOtherApps: true)
        sessionManager.openWorkspace(layout, hosts: hosts)
    }
}
