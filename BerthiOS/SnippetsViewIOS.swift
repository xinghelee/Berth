import SwiftData
import SwiftUI

/// iOS 命令片段:管理 + 点按发送(带 {{变量}} 填值)。
/// insertHandler 非空时为"插入模式"(从终端页打开,点片段即发送)。
struct SnippetsViewIOS: View {
    let insertHandler: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Snippet.sortOrder) private var snippets: [Snippet]
    @State private var theme = ThemeStore.shared

    @State private var editing: Snippet?
    @State private var isCreating = false
    @State private var variableFill: VariableFillRequest?

    struct VariableFillRequest: Identifiable {
        let id = UUID()
        let template: String
        let variables: [String]
    }

    var body: some View {
        NavigationStack {
            Group {
                if snippets.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "还没有片段"), systemImage: "curlybraces")
                    } description: {
                        Text(String(localized: "命令里用 {{变量}} 可在发送时填值"))
                    } actions: {
                        Button(String(localized: "新建片段")) { isCreating = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(snippets) { snippet in
                            snippetRow(snippet)
                                .listRowBackground(theme.current.panelBackground)
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(snippets[index]) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "命令片段"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isCreating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isCreating) { SnippetEditorIOS(snippet: nil) }
            .sheet(item: $editing) { snippet in SnippetEditorIOS(snippet: snippet) }
            .sheet(item: $variableFill) { request in
                VariableFillSheet(request: request) { resolved in
                    send(resolved)
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        Button {
            tap(snippet)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.title).fontWeight(.medium)
                Text(snippet.command)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(2)
                    .foregroundStyle(theme.current.secondaryText)
            }
        }
        .contextMenu {
            Button { editing = snippet } label: { Label(String(localized: "编辑…"), systemImage: "pencil") }
            Button(role: .destructive) { modelContext.delete(snippet) } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
    }

    private func tap(_ snippet: Snippet) {
        guard insertHandler != nil else {
            editing = snippet
            return
        }
        let variables = Self.extractVariables(from: snippet.command)
        if variables.isEmpty {
            send(snippet.command)
        } else {
            variableFill = VariableFillRequest(template: snippet.command, variables: variables)
        }
    }

    private func send(_ command: String) {
        insertHandler?(command)
        dismiss()
    }

    /// {{变量}} 提取,保持出现顺序、去重
    static func extractVariables(from template: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var rest = template[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, seen.insert(name).inserted {
                result.append(name)
            }
            rest = rest[close.upperBound...]
        }
        return result
    }

    static func substitute(_ template: String, values: [String: String]) -> String {
        var output = template
        for (name, value) in values {
            output = output.replacingOccurrences(of: "{{\(name)}}", with: value)
            output = output.replacingOccurrences(of: "{{ \(name) }}", with: value)
        }
        return output
    }
}

/// 片段编辑
struct SnippetEditorIOS: View {
    let snippet: Snippet?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var theme = ThemeStore.shared
    @State private var title = ""
    @State private var command = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "标题"), text: $title)
                    .listRowBackground(theme.current.panelBackground)
                Section {
                    TextField(String(localized: "命令(可含 {{变量}})"), text: $command, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(theme.current.panelBackground)
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(snippet == nil ? String(localized: "新建片段") : String(localized: "编辑片段"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) { save() }
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let snippet {
                    title = snippet.title
                    command = snippet.command
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private func save() {
        if let snippet {
            snippet.title = title.isEmpty ? command : title
            snippet.command = command
        } else {
            let created = Snippet(title: title.isEmpty ? command : title, command: command)
            modelContext.insert(created)
        }
        dismiss()
    }
}

/// {{变量}} 填值
struct VariableFillSheet: View {
    let request: SnippetsViewIOS.VariableFillRequest
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeStore.shared
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(request.variables, id: \.self) { name in
                    TextField(name, text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(theme.current.panelBackground)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "填写变量"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "发送")) {
                        let resolved = SnippetsViewIOS.substitute(request.template, values: values)
                        dismiss()
                        onSend(resolved)
                    }
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }
}
