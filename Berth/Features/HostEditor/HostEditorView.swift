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
    @Query(sort: \SSHKeyRecord.createdAt, order: .reverse) private var storedKeys: [SSHKeyRecord]

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethodKind = .password
    @State private var password = ""
    @State private var privateKeyPath = ""
    @State private var passphrase = ""
    @State private var selectedKeyID: UUID?
    @State private var groupID: UUID?
    @State private var tagColor: TagColor = .none
    @State private var note = ""
    @State private var validationMessage: String?
    @State private var quickFill = ""

    private var isEditing: Bool { host != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !isEditing {
                    Section {
                        TextField(
                            "快速新建",
                            text: $quickFill,
                            prompt: Text("粘贴 user@host:port 或 ssh 命令,自动填充下方字段")
                        )
                        .onChange(of: quickFill) { _, newValue in
                            applyQuickFill(newValue)
                        }
                    }
                }
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
                        Text("密钥库").tag(AuthMethodKind.storedKey)
                    }
                    .pickerStyle(.segmented)

                    switch authMethod {
                    case .password:
                        SecureField(
                            "密码",
                            text: $password,
                            prompt: Text(isEditing ? "留空保持不变" : "密码")
                        )
                    case .privateKeyFile:
                        HStack {
                            TextField("私钥路径", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                            Button("选择…") { pickPrivateKey() }
                        }
                        SecureField(
                            "Passphrase",
                            text: $passphrase,
                            prompt: Text(isEditing ? "留空保持不变" : "没有则不填")
                        )
                    case .storedKey:
                        if storedKeys.isEmpty {
                            Text("密钥库是空的,先到侧栏「密钥」页生成或导入。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("密钥", selection: $selectedKeyID) {
                                Text("未选择").tag(UUID?.none)
                                ForEach(storedKeys) { key in
                                    Text("\(key.name)(\(key.keyType))").tag(UUID?.some(key.id))
                                }
                            }
                        }
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

    private func applyQuickFill(_ input: String) {
        guard let parsed = SSHCommandParser.parse(input) else { return }
        hostname = parsed.hostname
        if let user = parsed.username { username = user }
        if let parsedPort = parsed.port { port = String(parsedPort) }
        if let identityFile = parsed.identityFile {
            authMethod = .privateKeyFile
            privateKeyPath = identityFile
        }
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
        selectedKeyID = host.keyID
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
        if authMethod == .storedKey && selectedKeyID == nil {
            validationMessage = "请选择密钥库中的密钥。"
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
        target.keyID = authMethod == .storedKey ? selectedKeyID : nil
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
