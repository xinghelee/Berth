import SwiftData
import SwiftUI

/// ⌘P 全局命令面板:模糊搜索聚合「动作」+「主机」,回车执行/连接。
struct CommandPaletteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query private var hosts: [Host]

    @State private var query = ""
    @State private var selectionIndex = 0
    @State private var themeStore = ThemeStore.shared
    @FocusState private var isFieldFocused: Bool

    private let controller = CommandPaletteController.shared

    private enum Row: Identifiable {
        case command(PaletteCommand)
        case host(Host)
        var id: String {
            switch self {
            case .command(let c): return "cmd." + c.id
            case .host(let h): return "host." + h.id.uuidString
            }
        }
    }

    // MARK: - 命令清单

    private var commands: [PaletteCommand] {
        let m = sessionManager
        let hasSession = m.selected != nil
        var list: [PaletteCommand] = [
            PaletteCommand(id: "quickconnect", title: "快速连接…", subtitle: "⌘K", icon: "bolt.fill") {
                QuickConnectController.shared.toggle()
            },
            PaletteCommand(id: "split-h", title: "左右分屏", subtitle: "⌘D", icon: "rectangle.split.2x1", isEnabled: hasSession) {
                m.splitFocused(axis: .horizontal)
            },
            PaletteCommand(id: "split-v", title: "上下分屏", subtitle: "⌘⇧D", icon: "rectangle.split.1x2", isEnabled: hasSession) {
                m.splitFocused(axis: .vertical)
            },
            PaletteCommand(id: "close-pane", title: "关闭当前分屏", subtitle: "⌘W", icon: "xmark.rectangle", isEnabled: hasSession) {
                m.requestCloseCurrent()
            },
            PaletteCommand(id: "dup", title: "复制当前连接为新标签", subtitle: "⌘T", icon: "plus.square.on.square", isEnabled: hasSession) {
                m.duplicateCurrent()
            },
            PaletteCommand(id: "sftp", title: m.isSFTPVisible ? "关闭 SFTP 文件面板" : "打开 SFTP 文件面板", subtitle: "⌘⇧F", icon: "folder", isEnabled: hasSession) {
                m.isSFTPVisible.toggle()
            },
            PaletteCommand(id: "inspector", title: m.isInspectorVisible ? "关闭服务器信息面板" : "打开服务器信息面板", subtitle: "⌘I", icon: "sidebar.right", isEnabled: hasSession) {
                m.isInspectorVisible.toggle()
            },
            PaletteCommand(id: "find", title: "在终端中查找", subtitle: "⌘F", icon: "magnifyingglass", isEnabled: hasSession) {
                m.requestSearch()
            },
            PaletteCommand(id: "keys", title: "密钥管理", icon: "key") {
                openWindow(id: "keys")
            },
        ]
        // 主题切换命令
        for theme in TerminalTheme.builtIn {
            list.append(PaletteCommand(
                id: "theme." + theme.id,
                title: "主题:\(theme.name)",
                subtitle: themeStore.current.id == theme.id ? "当前" : nil,
                icon: "paintpalette"
            ) {
                themeStore.select(id: theme.id)
            })
        }
        return list
    }

    private var rows: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // 空查询:常用动作在前 + 最近连接的主机
            let recentHosts = hosts
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
                .prefix(5)
            return commands.prefix(8).map(Row.command) + recentHosts.map(Row.host)
        }
        // 命令模糊匹配
        let scoredCmds: [(PaletteCommand, Int)] = commands.compactMap { c in
            guard let s = FuzzyMatcher.bestScore(query: trimmed, fields: [c.title, c.subtitle]) else { return nil }
            return (c, s)
        }
        // 主机模糊匹配
        let scoredHosts: [(Host, Int)] = hosts.compactMap { h in
            guard let s = FuzzyMatcher.bestScore(query: trimmed, fields: [h.label, h.hostname, h.username, h.group?.name]) else { return nil }
            return (h, s)
        }
        let cmdRows = scoredCmds.sorted { $0.1 > $1.1 }.prefix(6).map { Row.command($0.0) }
        let hostRows = scoredHosts.sorted { $0.1 > $1.1 }.prefix(6).map { Row.host($0.0) }
        return Array(cmdRows) + Array(hostRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("搜索命令或主机…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFieldFocused)
                    .onSubmit { activate() }
            }
            .padding(14)

            if !rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, isSelected: index == selectionIndex)
                                    .id(index)
                                    .onHover { if $0 { selectionIndex = index } }
                                    .onTapGesture { selectionIndex = index; activate() }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectionIndex) { _, i in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 580)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .onAppear { query = ""; selectionIndex = 0; isFieldFocused = true }
        .onChange(of: query) { _, _ in selectionIndex = 0 }
        .onKeyPress(.downArrow) { selectionIndex = min(selectionIndex + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selectionIndex = max(selectionIndex - 1, 0); return .handled }
        .onKeyPress(.escape) { controller.dismiss(); return .handled }
        .onExitCommand { controller.dismiss() }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .command(let c):
                Image(systemName: c.icon)
                    .frame(width: 18)
                    .foregroundStyle(c.isEnabled ? .primary : .tertiary)
                Text(c.title)
                    .foregroundStyle(c.isEnabled ? .primary : .tertiary)
                Spacer()
                if let sub = c.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.tertiary)
                }
            case .host(let host):
                Circle().fill(host.tagColor.color).frame(width: 8, height: 8)
                    .opacity(host.tagColor == .none ? 0.2 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.label)
                    Text(host.address).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("连接").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard rows.indices.contains(selectionIndex) else { return }
        switch rows[selectionIndex] {
        case .command(let c):
            guard c.isEnabled else { return }
            controller.dismiss()
            c.run()
        case .host(let host):
            controller.dismiss()
            host.lastConnectedAt = Date()
            try? modelContext.save()
            sessionManager.open(spec: HostSpec.resolve(host, in: hosts))
        }
    }
}
