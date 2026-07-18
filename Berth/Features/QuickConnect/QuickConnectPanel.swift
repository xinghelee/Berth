import SwiftData
import SwiftUI

/// ⌘K 快速连接面板:模糊搜索主机,↑↓ 选择,回车连接;
/// 输入形如 user@host 且需要时可临时直连。
struct QuickConnectPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Query private var storedHosts: [Host]
    @AppStorage(SettingsKeys.demoMode) private var demoMode = false

    /// 托管主机(库)+ config 镜像(内存);演示模式下换内置示例(防录屏/截图泄漏)
    private var hosts: [Host] {
        demoMode ? DemoMode.samples : storedHosts + SSHConfigService.shared.mirrorHosts
    }

    @State private var query = ""
    @State private var selectionIndex = 0

    private let controller = QuickConnectController.shared

    private enum Row: Identifiable {
        case host(Host, score: Int)
        case direct(ParsedSSHTarget)

        var id: String {
            switch self {
            case .host(let host, _): return host.id.uuidString
            case .direct: return "direct"
            }
        }
    }

    private var rows: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var result: [Row] = []

        if trimmed.isEmpty {
            // 空查询:按最近连接排序给出常用主机
            let recent = hosts
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
                .prefix(8)
            result = recent.map { .host($0, score: 0) }
        } else {
            let scored: [(Host, Int)] = hosts.compactMap { host in
                let fields = [host.label, host.hostname, host.username, host.group?.name]
                guard let score = FuzzyMatcher.bestScore(query: trimmed, fields: fields) else { return nil }
                return (host, score)
            }
            result = scored
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map { .host($0.0, score: $0.1) }

            if let parsed = SSHCommandParser.parse(trimmed), parsed.username != nil {
                result.append(.direct(parsed))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.secondary)
                PaletteTextField(
                    text: $query,
                    placeholder: String(localized: "搜索主机,或输入 user@host 直连"),
                    onMoveUp: { selectionIndex = max(selectionIndex - 1, 0) },
                    onMoveDown: { selectionIndex = min(selectionIndex + 1, max(rows.count - 1, 0)) },
                    onSubmit: { activateSelection() },
                    onCancel: { controller.dismiss() }
                )
                .frame(height: 22)
            }
            .padding(14)

            if !rows.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isSelected: index == selectionIndex)
                            .onHover { hovering in
                                // 悬停即选中(launcher 惯例),与键盘上下键共用同一选中态
                                if hovering { selectionIndex = index }
                            }
                            .onTapGesture {
                                selectionIndex = index
                                activateSelection()
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            query = ""
            selectionIndex = 0
        }
        .onChange(of: query) { _, _ in selectionIndex = 0 }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .host(let host, _):
                Circle()
                    .fill(host.tagColor.color)
                    .frame(width: 8, height: 8)
                    .opacity(host.tagColor == .none ? 0.15 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.label)
                    Text(host.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if host.source == .sshConfig {
                    Text("config")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
            case .direct(let target):
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.tint)
                Text("直接连接 \(target.username ?? "")@\(target.hostname)\(target.port.map { ":\($0)" } ?? "")")
                Spacer()
                Text("回车")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func activateSelection() {
        guard rows.indices.contains(selectionIndex) else { return }
        switch rows[selectionIndex] {
        case .host(let host, _):
            host.lastConnectedAt = Date()
            try? modelContext.save()
            sessionManager.open(spec: HostSpec.resolve(host, in: hosts))
            controller.dismiss()
        case .direct(let target):
            controller.directConnectRequest = DirectConnectRequest(target: target)
            controller.dismiss()
        }
    }
}
