import SwiftData
import SwiftUI

/// iOS 主机编辑器:连接 / 认证(密码·密钥库)/ 跳板机 / 代理 / 端口转发 / 整理 / 增强。
/// 与 Mac 版 HostEditorView 字段对齐;私钥文件与 agent 认证在 iOS 不适用,不提供。
struct HostEditorIOS: View {
    let host: Host?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Host.sortOrder) private var allHosts: [Host]
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @State private var theme = ThemeStore.shared

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethodKind = .password
    @State private var password = ""
    @State private var keyID: UUID?
    @State private var jumpHostID: UUID?
    @State private var proxyKind: ProxyKind = .none
    @State private var proxyHost = ""
    @State private var proxyPort = "1080"
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var groupID: UUID?
    @State private var tagColor: TagColor = .none
    @State private var isProduction = false
    @State private var startupCommands = ""
    @State private var forwards: [ForwardDraft] = []
    @State private var validationMessage: String?

    struct ForwardDraft: Identifiable {
        let id = UUID()
        var kind: PortForwardKind = .local
        var bindPort = ""
        var targetHost = "127.0.0.1"
        var targetPort = ""
        var existingID: UUID?
    }

    var body: some View {
        NavigationStack {
            Form {
                connectSection
                authSection
                routeSection
                forwardSection
                organizeSection
                extrasSection
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(host == nil ? String(localized: "新建主机") : String(localized: "编辑主机"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) { save() }
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    // MARK: - 分区

    private var connectSection: some View {
        Section(String(localized: "连接")) {
            TextField(String(localized: "显示名"), text: $label, prompt: Text(hostname.isEmpty ? String(localized: "例如:生产环境 API") : hostname))
            TextField(String(localized: "主机地址"), text: $hostname)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(String(localized: "端口"), text: $port)
                .keyboardType(.numberPad)
            TextField(String(localized: "用户名"), text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .listRowBackground(theme.current.panelBackground)
    }

    private var authSection: some View {
        Section(String(localized: "认证")) {
            Picker(String(localized: "认证方式"), selection: $authMethod) {
                Text(String(localized: "密码")).tag(AuthMethodKind.password)
                Text(String(localized: "密钥库")).tag(AuthMethodKind.storedKey)
            }
            if authMethod == .password {
                SecureField(host == nil ? String(localized: "密码") : String(localized: "密码(可选,留空保持不变)"), text: $password)
            } else if keys.isEmpty {
                Text(String(localized: "密钥库是空的,先到「密钥」页生成或导入。"))
                    .font(.caption)
                    .foregroundStyle(theme.current.secondaryText)
            } else {
                Picker(String(localized: "密钥"), selection: $keyID) {
                    Text(String(localized: "未选择")).tag(UUID?.none)
                    ForEach(keys) { key in
                        Text(key.name).tag(UUID?.some(key.id))
                    }
                }
            }
        }
        .listRowBackground(theme.current.panelBackground)
    }

    private var routeSection: some View {
        Section(String(localized: "跳板机与代理")) {
            Picker(String(localized: "跳板机"), selection: $jumpHostID) {
                Text(String(localized: "不使用")).tag(UUID?.none)
                ForEach(allHosts.filter { $0.id != host?.id }) { candidate in
                    Text(candidate.label).tag(UUID?.some(candidate.id))
                }
            }
            Picker(String(localized: "代理"), selection: $proxyKind) {
                Text(String(localized: "不使用")).tag(ProxyKind.none)
                Text("HTTP").tag(ProxyKind.http)
                Text("SOCKS5").tag(ProxyKind.socks5)
            }
            if proxyKind != .none {
                TextField(String(localized: "代理主机"), text: $proxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(String(localized: "代理端口"), text: $proxyPort)
                    .keyboardType(.numberPad)
                TextField(String(localized: "用户名(可选)"), text: $proxyUsername)
                    .textInputAutocapitalization(.never)
                SecureField(String(localized: "密码(可选,留空保持不变)"), text: $proxyPassword)
            }
        }
        .listRowBackground(theme.current.panelBackground)
    }

    private var forwardSection: some View {
        Section(String(localized: "端口转发")) {
            ForEach($forwards) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    Picker(String(localized: "类型"), selection: $draft.kind) {
                        Text(String(localized: "本地 (-L)")).tag(PortForwardKind.local)
                        Text(String(localized: "远程 (-R)")).tag(PortForwardKind.remote)
                        Text(String(localized: "动态 SOCKS5 (-D)")).tag(PortForwardKind.dynamic)
                    }
                    HStack {
                        TextField(draft.kind == .remote ? String(localized: "远端端口") : String(localized: "本地端口"), text: $draft.bindPort)
                            .keyboardType(.numberPad)
                        if draft.kind != .dynamic {
                            Text("→").foregroundStyle(theme.current.secondaryText)
                            TextField(String(localized: "目标主机"), text: $draft.targetHost)
                                .textInputAutocapitalization(.never)
                            TextField(String(localized: "端口"), text: $draft.targetPort)
                                .keyboardType(.numberPad)
                        }
                    }
                    .font(.callout)
                }
            }
            .onDelete { forwards.remove(atOffsets: $0) }
            Button {
                forwards.append(ForwardDraft())
            } label: {
                Label(String(localized: "添加转发"), systemImage: "plus")
            }
        }
        .listRowBackground(theme.current.panelBackground)
    }

    private var organizeSection: some View {
        Section(String(localized: "整理")) {
            Picker(String(localized: "分组"), selection: $groupID) {
                Text(String(localized: "无分组")).tag(UUID?.none)
                ForEach(groups) { group in
                    Text(group.name).tag(UUID?.some(group.id))
                }
            }
            Picker(String(localized: "标签色"), selection: $tagColor) {
                Text(String(localized: "无")).tag(TagColor.none)
                Text(String(localized: "红(生产)")).tag(TagColor.red)
                Text(String(localized: "橙")).tag(TagColor.orange)
                Text(String(localized: "绿")).tag(TagColor.green)
                Text(String(localized: "蓝")).tag(TagColor.blue)
                Text(String(localized: "紫")).tag(TagColor.purple)
            }
            Toggle(String(localized: "生产环境"), isOn: $isProduction)
        }
        .listRowBackground(theme.current.panelBackground)
    }

    private var extrasSection: some View {
        Section {
            TextField(String(localized: "每行一条,例如:\ncd /app\ntmux attach || tmux"), text: $startupCommands, axis: .vertical)
                .lineLimit(2...6)
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(String(localized: "连接后自动执行"))
        } footer: {
            Text(String(localized: "连接建立后按顺序自动发送(各自动补回车)。"))
                .foregroundStyle(theme.current.secondaryText)
        }
        .listRowBackground(theme.current.panelBackground)
    }

    // MARK: - 读写

    private func loadExisting() {
        guard let host else { return }
        label = host.label
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod == .storedKey ? .storedKey : .password
        keyID = host.keyID
        jumpHostID = host.jumpHostID
        proxyKind = host.proxy.kind
        proxyHost = host.proxy.host
        proxyPort = String(host.proxy.port)
        proxyUsername = host.proxy.username
        groupID = host.group?.id
        tagColor = host.tagColor
        isProduction = host.isProduction
        startupCommands = host.startupCommands
        forwards = (host.portForwards ?? []).sorted { $0.sortOrder < $1.sortOrder }.map {
            ForwardDraft(
                kind: $0.kind,
                bindPort: String($0.bindPort),
                targetHost: $0.targetHost,
                targetPort: String($0.targetPort),
                existingID: $0.id
            )
        }
    }

    private func save() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            validationMessage = String(localized: "主机地址和用户名不能为空。")
            return
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            validationMessage = String(localized: "端口需要是 1-65535 之间的数字。")
            return
        }
        if authMethod == .storedKey, keyID == nil {
            validationMessage = String(localized: "请选择密钥库中的密钥。")
            return
        }

        var proxy = ProxyConfig()
        proxy.kind = proxyKind
        if proxyKind != .none {
            proxy.host = proxyHost.trimmingCharacters(in: .whitespaces)
            proxy.port = Int(proxyPort) ?? 1080
            proxy.username = proxyUsername
        }

        let target: Host
        if let host {
            target = host
            target.label = label.isEmpty ? trimmedHost : label
            target.hostname = trimmedHost
            target.port = portNumber
            target.username = trimmedUser
            target.authMethod = authMethod
            target.keyID = authMethod == .storedKey ? keyID : nil
        } else {
            target = Host(
                label: label.isEmpty ? trimmedHost : label,
                hostname: trimmedHost,
                port: portNumber,
                username: trimmedUser,
                authMethod: authMethod,
                keyID: authMethod == .storedKey ? keyID : nil
            )
            modelContext.insert(target)
        }
        target.jumpHostID = jumpHostID
        target.proxy = proxy
        target.group = groupID.flatMap { id in groups.first { $0.id == id } }
        target.tagColor = tagColor
        target.isProduction = isProduction
        target.startupCommands = startupCommands

        // 端口转发:重建(草稿保留原 id 以免状态错乱)
        for existing in target.portForwards ?? [] {
            modelContext.delete(existing)
        }
        for (index, draft) in forwards.enumerated() {
            guard let bind = Int(draft.bindPort), (1...65535).contains(bind) else { continue }
            let targetPort = draft.kind == .dynamic ? 0 : (Int(draft.targetPort) ?? 0)
            if draft.kind != .dynamic {
                guard (1...65535).contains(targetPort) else { continue }
            }
            let forward = PortForward(
                kind: draft.kind,
                bindHost: "127.0.0.1",
                bindPort: bind,
                targetHost: draft.kind == .dynamic ? "" : draft.targetHost,
                targetPort: targetPort,
                sortOrder: index
            )
            forward.host = target
            modelContext.insert(forward)
        }

        if authMethod == .password, !password.isEmpty {
            try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: target.id))
        }
        if proxyKind != .none, !proxyPassword.isEmpty {
            try? KeychainStore.save(proxyPassword, account: KeychainStore.proxyPasswordAccount(for: target.id))
        }
        dismiss()
    }
}
