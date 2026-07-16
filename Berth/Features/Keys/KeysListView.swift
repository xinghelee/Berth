import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 密钥管理页(侧栏「密钥」)。生成 ed25519、导入 PEM、复制公钥 /
/// ssh-copy-id 等效命令、删除。私钥内容不离开 Keychain。
struct KeysListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKeyRecord.createdAt, order: .reverse) private var keys: [SSHKeyRecord]

    @State private var isGenerating = false
    @State private var isImporting = false
    @State private var keyPendingDeletion: SSHKeyRecord?
    @State private var copyFeedback: String?

    var body: some View {
        Group {
            if keys.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(keys) { key in
                        KeyRowView(key: key)
                            .contextMenu { menuItems(for: key) }
                    }
                }
            }
        }
        .navigationTitle("密钥")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isGenerating = true
                } label: {
                    Label("生成密钥", systemImage: "plus")
                }
                Button {
                    isImporting = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $isGenerating) { GenerateKeySheet() }
        .sheet(isPresented: $isImporting) { ImportKeySheet() }
        .confirmationDialog(
            "删除密钥「\(keyPendingDeletion?.name ?? "")」?",
            isPresented: Binding(
                get: { keyPendingDeletion != nil },
                set: { if !$0 { keyPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let key = keyPendingDeletion {
                    KeyStore.delete(key, context: modelContext)
                }
                keyPendingDeletion = nil
            }
            Button("取消", role: .cancel) { keyPendingDeletion = nil }
        } message: {
            if let key = keyPendingDeletion {
                let count = KeyStore.hostsUsing(keyID: key.id, context: modelContext)
                Text(count > 0
                    ? "有 \(count) 台主机正在使用该密钥,删除后它们将无法连接。Keychain 中的私钥会一并删除,此操作不可撤销。"
                    : "Keychain 中的私钥会一并删除,此操作不可撤销。")
            }
        }
    }

    @ViewBuilder
    private func menuItems(for key: SSHKeyRecord) -> some View {
        Button("复制公钥") {
            copyToPasteboard(key.publicKey)
        }
        Button("复制 ssh-copy-id 等效命令") {
            copyToPasteboard(OpenSSHFormat.sshCopyIDCommand(
                publicKey: key.publicKey,
                username: "user",
                hostname: "host",
                port: 22
            ))
        }
        Divider()
        Button("删除…", role: .destructive) { keyPendingDeletion = key }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "key")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("密钥库是空的")
                .font(.title3)
            HStack {
                Button {
                    isGenerating = true
                } label: {
                    Label("生成 ed25519 密钥", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button("导入现有密钥…") { isImporting = true }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct KeyRowView: View {
    let key: SSHKeyRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                Text("\(key.keyType) · \(key.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 生成

private struct GenerateKeySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("生成 ed25519 密钥") {
                    TextField("名称", text: $name, prompt: Text("例如:个人 VPS"))
                    Text("私钥只保存在 macOS Keychain 中,不写入磁盘文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("生成") {
                    do {
                        try KeyStore.generateEd25519(name: name, context: modelContext)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 400, height: 230)
    }
}

// MARK: - 导入

private struct ImportKeySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pemText = ""
    @State private var passphrase = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("导入私钥") {
                    TextField("名称", text: $name)
                    HStack(alignment: .top) {
                        TextEditor(text: $pemText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 120)
                        Button("选择文件…") { pickFile() }
                    }
                    SecureField("Passphrase(没有则不填)", text: $passphrase)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入") {
                    do {
                        try KeyStore.importKey(
                            name: name,
                            pemText: pemText,
                            passphrase: passphrase.isEmpty ? nil : passphrase,
                            context: modelContext
                        )
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pemText.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 340)
        .onAppear {
            // 粘贴板里如果已有私钥,顺手带入
            if let clipboard = NSPasteboard.general.string(forType: .string),
               clipboard.contains("PRIVATE KEY") {
                pemText = clipboard
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            pemText = text
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}
