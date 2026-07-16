import SwiftUI

/// 片段发送:无变量直接发到当前终端;有变量则弹出填值表单。
@MainActor
@Observable
final class SnippetRunController {
    static let shared = SnippetRunController()

    /// 待填变量的片段(非 nil 时 MainWindowView 弹表单)
    var pending: Snippet?
    /// 变量填值缓存
    var values: [String: String] = [:]

    func run(_ snippet: Snippet, in manager: SessionManager) {
        guard manager.selected != nil else { return }
        let vars = snippet.variables
        if vars.isEmpty {
            send(snippet, rendered: snippet.command, in: manager)
        } else {
            values = Dictionary(uniqueKeysWithValues: vars.map { ($0, "") })
            pending = snippet
        }
    }

    func confirm(in manager: SessionManager) {
        guard let snippet = pending else { return }
        send(snippet, rendered: snippet.render(with: values), in: manager)
        pending = nil
        values = [:]
    }

    func cancel() {
        pending = nil
        values = [:]
    }

    private func send(_ snippet: Snippet, rendered: String, in manager: SessionManager) {
        manager.selected?.sendText(rendered + "\n")
        snippet.useCount += 1
    }
}

/// 变量填值表单(MainWindowView 以 sheet 呈现)
struct SnippetRunSheet: View {
    let snippet: Snippet
    @Environment(SessionManager.self) private var sessionManager
    @State private var controller = SnippetRunController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填写变量").font(.headline)
            Text(snippet.title).font(.caption).foregroundStyle(.secondary)
            ForEach(snippet.variables, id: \.self) { name in
                TextField(name, text: Binding(
                    get: { controller.values[name] ?? "" },
                    set: { controller.values[name] = $0 }
                ))
            }
            Text(snippet.render(with: controller.values))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            HStack {
                Spacer()
                Button("取消") { controller.cancel() }
                Button("发送") { controller.confirm(in: sessionManager) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
