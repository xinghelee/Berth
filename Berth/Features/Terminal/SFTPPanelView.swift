import SwiftUI
import UniformTypeIdentifiers

/// 终端右侧 SFTP 文件面板:路径栏 + 文件列表 + 上传/新建 + 拖入上传。
struct SFTPPanelView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var browser: SFTPBrowser?
    @State private var renaming: SFTPBrowser.Entry?
    @State private var renameText = ""
    @State private var creatingDir = false
    @State private var newDirName = ""
    @State private var pendingDelete: SFTPBrowser.Entry?
    @State private var isDropTargeted = false
    @State private var hoveredEntryID: UUID?
    @State private var chmodEntry: SFTPBrowser.Entry?
    @State private var chmodMode: UInt32 = 0
    @State private var previewEntry: SFTPBrowser.Entry?
    @State private var previewText: String?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var isSessionConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            pathBar
            Divider().overlay(theme.borderColor)
            content
            if let transfer = browser?.transfer {
                transferBar(transfer)
            }
        }
        .frame(width: 300)
        .background(theme.panelBackground)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .task(id: session.id) {
            let browser = SFTPBrowser { try await session.openSFTP() }
            self.browser = browser
            await browser.start()
        }
        .onChange(of: isSessionConnected) { _, connected in
            // 面板先于连接打开(或断线重连后):连上即自动重试打开 SFTP,不再永久停在失败态
            if connected {
                Task { await browser?.refresh() }
            }
        }
        .onDisappear { browser?.close() }
        .sheet(item: $chmodEntry) { entry in
            ChmodSheet(entry: entry, mode: $chmodMode) {
                Task { await browser?.chmod(entry, mode: chmodMode) }
                chmodEntry = nil
            } cancel: { chmodEntry = nil }
        }
        .sheet(item: $previewEntry) { entry in
            PreviewSheet(name: entry.name, text: previewText) { previewEntry = nil }
        }
    }

    private var header: some View {
        PanelHeader(title: "文件") {
            PanelIconButton(symbol: "folder.badge.plus", help: "新建文件夹") { creatingDir = true }
            PanelIconButton(symbol: "square.and.arrow.up", help: "上传文件") { uploadPick() }
            PanelIconButton(symbol: "arrow.clockwise", help: "刷新") { Task { await browser?.refresh() } }
            PanelIconButton(symbol: "xmark", help: "关闭") { onClose() }
        }
        .alert("新建文件夹", isPresented: $creatingDir) {
            TextField("名称", text: $newDirName)
            Button("创建") {
                let name = newDirName.trimmingCharacters(in: .whitespaces)
                newDirName = ""
                Task { await browser?.makeDirectory(name: name) }
            }
            Button("取消", role: .cancel) { newDirName = "" }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button {
                Task { await browser?.goUp() }
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(browser?.path == "/" ? .tertiary : .secondary)
                .disabled(browser?.path == "/")
            Text(browser?.path ?? "/")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            // 书签菜单
            Menu {
                Button(browser?.isCurrentBookmarked == true ? "取消收藏此目录" : "收藏此目录") {
                    browser?.toggleBookmark()
                }
                if let bms = browser?.bookmarks, !bms.isEmpty {
                    Divider()
                    ForEach(bms, id: \.self) { path in
                        Button(path) { Task { await browser?.navigate(to: path) } }
                    }
                }
            } label: {
                Image(systemName: browser?.isCurrentBookmarked == true ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(browser?.isCurrentBookmarked == true ? theme.accentColor : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("目录书签")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch browser?.state {
        case .loading, .idle, nil:
            centered { ProgressView().controlSize(.small) }
        case .failed(let message):
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        case .ready:
            if browser?.entries.isEmpty == true {
                centered { Text("空目录").font(.caption).foregroundStyle(.secondary) }
            } else {
                fileList
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser?.entries ?? []) { entry in
                    row(entry)
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog(
            "删除「\(pendingDelete?.name ?? "")」?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { Task { await browser?.delete(entry) } }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") {
                if let entry = renaming { Task { await browser?.rename(entry, to: renameText) } }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ entry: SFTPBrowser.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "arrow.up.right" : "doc"))
                .font(.system(size: 13))
                .foregroundStyle(entry.isDirectory ? theme.accentColor : Color.secondary)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            editBadge(entry)
            if !entry.isDirectory {
                Text(sizeText(entry.size))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredEntryID == entry.id ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
                .animation(.easeOut(duration: 0.12), value: hoveredEntryID)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : (hoveredEntryID == entry.id ? nil : hoveredEntryID)
        }
        .onTapGesture(count: 2) {
            if entry.isDirectory || entry.isSymlink {
                Task { await browser?.enter(entry) }
            } else {
                browser?.editRemotely(entry) // 双击文件 = 本地编辑器打开并自动回传
            }
        }
        .contextMenu {
            if entry.isDirectory {
                Button("打开") { Task { await browser?.enter(entry) } }
            } else {
                Button("预览") { previewEntry = entry; Task { previewText = await browser?.previewText(entry) ?? "(无法预览:二进制或过大)" } }
                Button("用本地编辑器打开") { browser?.editRemotely(entry) }
                if browser?.editing[browserRemotePath(entry)] != nil {
                    Button("停止编辑(取消自动回传)") { browser?.stopEditing(browserRemotePath(entry)) }
                }
                Button("下载…") { downloadPick(entry) }
            }
            Button("重命名…") { renaming = entry; renameText = entry.name }
            Button("权限…") { chmodEntry = entry; chmodMode = entry.mode }
            Divider()
            Button("删除…", role: .destructive) { pendingDelete = entry }
        }
    }

    /// 编辑态角标:同步中转圈,失败显示叹号
    @ViewBuilder
    private func editBadge(_ entry: SFTPBrowser.Entry) -> some View {
        if let state = browser?.editing[browserRemotePath(entry)] {
            switch state {
            case .syncing:
                ProgressView().controlSize(.mini)
            case .idle:
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accentColor)
                    .help("编辑中,保存即自动回传")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("回传失败")
            }
        }
    }

    private func browserRemotePath(_ entry: SFTPBrowser.Entry) -> String {
        let base = browser?.path ?? "/"
        return base == "/" ? "/\(entry.name)" : "\(base)/\(entry.name)"
    }

    private func transferBar(_ text: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if browser?.transferProgress == nil {
                    ProgressView().controlSize(.mini)
                }
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let p = browser?.transferProgress {
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let p = browser?.transferProgress {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.elevatedBackground)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 操作

    private func downloadPick(_ entry: SFTPBrowser.Entry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        if panel.runModal() == .OK, let url = panel.url {
            Task { await browser?.download(entry, to: url) }
        }
    }

    private func uploadPick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await browser?.upload(from: url) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in await browser?.upload(from: url) }
            }
        }
        return true
    }

    private func sizeText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// chmod 权限编辑:owner/group/other × r/w/x 复选 + 八进制显示
private struct ChmodSheet: View {
    let entry: SFTPBrowser.Entry
    @Binding var mode: UInt32
    let apply: () -> Void
    let cancel: () -> Void

    private let rows: [(String, Int)] = [("所有者", 6), ("组", 3), ("其他", 0)]
    private let bits: [(String, UInt32)] = [("读", 4), ("写", 2), ("执行", 1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("权限:\(entry.name)").font(.headline)
            Grid(alignment: .leading) {
                GridRow {
                    Text("").frame(width: 48)
                    ForEach(bits, id: \.0) { Text($0.0).font(.caption).frame(width: 40) }
                }
                ForEach(rows, id: \.0) { rowName, shift in
                    GridRow {
                        Text(rowName).frame(width: 48, alignment: .leading)
                        ForEach(bits, id: \.0) { label, bit in
                            Toggle("", isOn: Binding(
                                get: { (mode >> shift) & bit != 0 },
                                set: { on in
                                    if on { mode |= (bit << shift) } else { mode &= ~(bit << shift) }
                                }
                            ))
                            .labelsHidden()
                            .frame(width: 40)
                        }
                    }
                }
            }
            Text(String(format: "八进制:%03o", mode))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("应用", action: apply).keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// 文本文件快速预览
private struct PreviewSheet: View {
    let name: String
    let text: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Button("关闭", action: close)
            }
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
    }
}
