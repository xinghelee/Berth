import Crypto
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

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            if keys.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(keys) { key in
                            KeyCardView(
                                key: key,
                                usageCount: KeyStore.hostsUsing(keyID: key.id, context: modelContext),
                                onDelete: { keyPendingDeletion = key }
                            )
                            .contextMenu { menuItems(for: key) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.panelBackground)
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

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("密钥")
                .font(.headline)
            if !keys.isEmpty {
                Text("\(keys.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            Menu {
                Button {
                    isGenerating = true
                } label: {
                    Label("生成 ed25519 密钥", systemImage: "sparkles")
                }
                Button {
                    isImporting = true
                } label: {
                    Label("导入现有密钥…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.accentSoft))
                    .foregroundStyle(theme.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("添加密钥")
        }
        .frame(height: AppLayout.topBarHeight)
        .padding(.horizontal, 12)
        .padding(.top, AppLayout.columnTopPadding)
        .padding(.bottom, 10)
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
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(theme.accentSoft)
                    .frame(width: 76, height: 76)
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.accentColor)
            }
            VStack(spacing: 6) {
                Text("密钥库是空的")
                    .font(.title3.weight(.semibold))
                Text("生成一把新密钥,或导入现有的 OpenSSH 私钥。\n私钥只保存在 macOS Keychain,不落盘。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button {
                    isGenerating = true
                } label: {
                    Label("生成 ed25519", systemImage: "sparkles")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    isImporting = true
                } label: {
                    Label("导入密钥", systemImage: "square.and.arrow.down")
                        .frame(minWidth: 110)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// 卡片式密钥行:图标 + 名称 + 类型徽章 + 指纹 + 悬停操作
private struct KeyCardView: View {
    let key: SSHKeyRecord
    let usageCount: Int
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var copied = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.accentSoft)
                    .frame(width: 38, height: 38)
                Image(systemName: "key.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(key.name)
                        .font(.body.weight(.medium))
                    keyTypeBadge
                    if usageCount > 0 {
                        Text("\(usageCount) 台主机")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                Text(fingerprint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isHovering {
                Button {
                    copyPublicKey()
                } label: {
                    Label(copied ? "已复制" : "复制公钥", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? Color.green : theme.accentColor)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(key.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.elevatedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isHovering ? theme.accentColor.opacity(0.3) : theme.borderColor, lineWidth: 1)
                )
        )
        .onHover { hovering in
            isHovering = hovering
            if !hovering { copied = false }
        }
    }

    private var keyTypeBadge: some View {
        Text(shortType)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(theme.accentSoft))
    }

    private var shortType: String {
        key.keyType
            .replacingOccurrences(of: "ssh-", with: "")
            .uppercased()
    }

    /// 从公钥行解析 base64 blob 算 SHA256 指纹(OpenSSH 风格)
    private var fingerprint: String {
        let parts = key.publicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return key.publicKey
        }
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    private func copyPublicKey() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(key.publicKey, forType: .string)
        copied = true
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
