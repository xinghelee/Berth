import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 新建/编辑主机表单。凭据只写 Keychain;编辑时密码留空表示保持不变。
/// M2 增加:粘贴 ssh 命令快速解析、SSHKey 实体选择。
struct HostEditorView: View {
    let host: Host?
    let defaultGroupID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethodKind = .password
    @State private var password = ""
    @State private var privateKeyPath = ""
    @State private var passphrase = ""
    @State private var groupID: UUID?
    @State private var tagColor: TagColor = .none
    @State private var note = ""
    @State private var validationMessage: String?

    private var isEditing: Bool { host != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("连接") {
                    TextField("显示名", text: $label, prompt: Text(hostname.isEmpty ? "例如:生产环境 API" : hostname))
                    TextField("主机地址", text: $hostname, prompt: Text("example.com 或 IP"))
                    TextField("端口", text: $port)
                    TextField("用户名", text: $username)
                }

                Section("认证") {
                    Picker("认证方式", selection: $authMethod) {
                        Text("密码").tag(AuthMethodKind.password)
                        Text("私钥文件").tag(AuthMethodKind.privateKeyFile)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .password {
                        SecureField(
                            "密码",
                            text: $password,
                            prompt: Text(isEditing ? "留空保持不变" : "密码")
                        )
                    } else {
                        HStack {
                            TextField("私钥路径", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                            Button("选择…") { pickPrivateKey() }
                        }
                        SecureField(
                            "Passphrase",
                            text: $passphrase,
                            prompt: Text(isEditing ? "留空保持不变" : "没有则不填")
                        )
                    }
                }

                Section("整理") {
                    Picker("分组", selection: $groupID) {
                        Text("无分组").tag(UUID?.none)
                        ForEach(groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    Picker("标签色", selection: $tagColor) {
                        ForEach(TagColor.allCases) { color in
                            Text(colorName(color)).tag(color)
                        }
                    }
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let message = validationMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "保存" : "创建") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: populate)
    }

    private func populate() {
        guard let host else {
            groupID = defaultGroupID
            return
        }
        label = host.label
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        privateKeyPath = host.privateKeyPath ?? ""
        groupID = host.group?.id
        tagColor = host.tagColor
        note = host.note
    }

    private func save() {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedHostname.isEmpty, !trimmedUsername.isEmpty else {
            validationMessage = "主机地址和用户名不能为空。"
            return
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            validationMessage = "端口需要是 1-65535 之间的数字。"
            return
        }
        if authMethod == .privateKeyFile && privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = "请选择私钥文件。"
            return
        }

        let displayLabel = label.trimmingCharacters(in: .whitespaces)
        let group = groupID.flatMap { id in groups.first { $0.id == id } }

        let target: Host
        if let host {
            target = host
        } else {
            target = Host(label: "", hostname: "", username: "")
            modelContext.insert(target)
        }

        target.label = displayLabel.isEmpty ? trimmedHostname : displayLabel
        target.hostname = trimmedHostname
        target.port = portNumber
        target.username = trimmedUsername
        target.authMethod = authMethod
        target.privateKeyPath = authMethod == .privateKeyFile
            ? privateKeyPath.trimmingCharacters(in: .whitespaces)
            : nil
        target.group = group
        target.tagColor = tagColor
        target.note = note

        do {
            if authMethod == .password {
                if !password.isEmpty {
                    try KeychainStore.save(password, account: KeychainStore.passwordAccount(for: target.id))
                }
                try? KeychainStore.delete(account: KeychainStore.passphraseAccount(for: target.id))
            } else {
                if !passphrase.isEmpty {
                    try KeychainStore.save(passphrase, account: KeychainStore.passphraseAccount(for: target.id))
                }
                try? KeychainStore.delete(account: KeychainStore.passwordAccount(for: target.id))
            }
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        dismiss()
    }

    private func pickPrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    private func colorName(_ color: TagColor) -> String {
        switch color {
        case .none: return "无"
        case .red: return "红(生产)"
        case .orange: return "橙"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }
}
