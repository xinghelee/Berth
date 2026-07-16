import SwiftData
import SwiftUI

/// 命令片段管理:增删改。发送在 ⌘P 命令面板或此处「发送到当前终端」。
struct SnippetsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Query(sort: [SortDescriptor(\Snippet.useCount, order: .reverse), SortDescriptor(\Snippet.createdAt)])
    private var snippets: [Snippet]

    @State private var editing: Snippet?
    @State private var isCreating = false
    @State private var runController = SnippetRunController.shared

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("命令片段").font(.headline)
                Spacer()
                Button { isCreating = true } label: { Image(systemName: "plus") }
                    .help("新建片段")
            }
            .padding(12)
            Divider().overlay(theme.borderColor)

            if snippets.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.badge.plus").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("还没有片段").foregroundStyle(.secondary)
                    Button("新建片段") { isCreating = true }.buttonStyle(.borderedProminent)
                    Text("命令里用 {{变量}} 可在发送时填值").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(snippets) { snippet in
                        row(snippet)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.panelBackground)
        .sheet(isPresented: $isCreating) { SnippetEditor(snippet: nil) }
        .sheet(item: $editing) { SnippetEditor(snippet: $0) }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).font(.system(size: 13, weight: .medium))
                Text(snippet.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                runController.run(snippet, in: sessionManager)
            } label: { Image(systemName: "paperplane") }
                .buttonStyle(.borderless)
                .help("发送到当前终端")
                .disabled(sessionManager.selected == nil)
        }
        .contextMenu {
            Button("发送到当前终端") { runController.run(snippet, in: sessionManager) }
                .disabled(sessionManager.selected == nil)
            Button("编辑…") { editing = snippet }
            Divider()
            Button("删除", role: .destructive) { modelContext.delete(snippet) }
        }
    }
}

/// 新建/编辑片段
private struct SnippetEditor: View {
    let snippet: Snippet?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var command = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet == nil ? "新建片段" : "编辑片段").font(.headline)
            TextField("标题", text: $title)
            TextField("命令(可含 {{变量}})", text: $command, axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3...8)
            TextField("备注(可选)", text: $note)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            if let s = snippet { title = s.title; command = s.command; note = s.note }
        }
    }

    private func save() {
        if let s = snippet {
            s.title = title; s.command = command; s.note = note
        } else {
            modelContext.insert(Snippet(title: title, command: command, note: note))
        }
        dismiss()
    }
}
