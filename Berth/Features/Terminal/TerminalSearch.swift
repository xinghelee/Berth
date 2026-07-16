import SwiftTerm
import SwiftUI

/// scrollback 搜索:扫描滚动缓冲全部行,匹配行可上下跳转(滚动定位)。
/// SwiftTerm 未公开高亮 API,MVP 用滚动定位到命中行;完整高亮留作后续细化。
@MainActor
@Observable
final class TerminalSearchModel {
    var query = ""
    private(set) var matches: [Int] = []   // scroll-invariant row 号
    private(set) var currentIndex = 0
    private(set) var totalScanned = 0

    weak var terminalView: TerminalView?

    var statusText: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "无匹配" }
        return "\(currentIndex + 1) / \(matches.count)"
    }

    func update(query: String) {
        self.query = query
        recompute()
    }

    func recompute() {
        matches = []
        currentIndex = 0
        guard let terminalView, !query.isEmpty else { return }
        let terminal = terminalView.getTerminal()
        let needle = query.lowercased()

        // scroll-invariant 行是连续区间,从命中的第一行向两端扩展找到边界
        var lower = 0
        while terminal.getScrollInvariantLine(row: lower - 1) != nil, lower > -100_000 { lower -= 1 }
        var upper = 0
        while terminal.getScrollInvariantLine(row: upper) != nil, upper < 100_000 { upper += 1 }

        var found: [Int] = []
        for row in lower..<upper {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            if line.translateToString(trimRight: true).lowercased().contains(needle) {
                found.append(row)
            }
        }
        totalScanned = upper - lower
        matches = found
        if !matches.isEmpty {
            currentIndex = matches.count - 1 // 默认定位到最近(最下)一条
            scrollToCurrent()
        }
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        scrollToCurrent()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        scrollToCurrent()
    }

    private func scrollToCurrent() {
        guard let terminalView, matches.indices.contains(currentIndex), totalScanned > 1 else { return }
        let row = matches[currentIndex]
        var lower = 0
        while terminalView.getTerminal().getScrollInvariantLine(row: lower - 1) != nil, lower > -100_000 { lower -= 1 }
        let position = Double(row - lower) / Double(max(totalScanned - 1, 1))
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }
}

/// ⌘F 搜索条(覆盖在终端顶部)
struct TerminalSearchBar: View {
    @Bindable var model: TerminalSearchModel
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("在回滚缓冲中搜索", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { model.next() }
                .onChange(of: model.query) { _, newValue in
                    model.update(query: newValue)
                }
                .frame(width: 220)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)
            Button {
                model.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.matches.isEmpty)
            Button {
                model.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(model.matches.isEmpty)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        )
        .padding(.top, 8)
        .onAppear { isFocused = true }
    }
}
