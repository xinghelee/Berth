import SwiftData
import SwiftUI

/// 快速连接:粘贴 user@host[:port] 或完整 ssh 命令,解析后直连;可当场输密码。
struct QuickConnectSheet: View {
    let onConnect: (QuickConnectRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var theme = ThemeStore.shared

    @State private var input = ""
    @State private var password = ""
    @State private var saveAsHost = false
    @State private var message: String?

    private var parsed: ParsedSSHTarget? {
        SSHCommandParser.parse(input)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "user@host:port 或 ssh 命令"), text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text(String(localized: "粘贴 user@host:port 或 ssh 命令,自动填充下方字段"))
                        .foregroundStyle(theme.current.secondaryText)
                }
                .listRowBackground(theme.current.panelBackground)

                if let parsed {
                    Section {
                        LabeledContent(String(localized: "主机"), value: parsed.hostname)
                        LabeledContent(String(localized: "用户"), value: parsed.username ?? "root")
                        LabeledContent(String(localized: "端口"), value: String(parsed.port ?? 22))
                        SecureField(String(localized: "密码(可选)"), text: $password)
                        Toggle(String(localized: "保存为主机"), isOn: $saveAsHost)
                    }
                    .listRowBackground(theme.current.panelBackground)
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "快速连接"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "连接")) { connect() }
                        .disabled(parsed == nil)
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private func connect() {
        guard let parsed else { return }
        let username = parsed.username ?? "root"
        let port = parsed.port ?? 22
        let hostID: UUID
        if saveAsHost {
            let host = Host(
                label: parsed.hostname,
                hostname: parsed.hostname,
                port: port,
                username: username
            )
            modelContext.insert(host)
            if !password.isEmpty {
                try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: host.id))
            }
            hostID = host.id
        } else {
            hostID = UUID()
        }
        let spec = HostSpec(
            hostID: hostID,
            label: "\(username)@\(parsed.hostname)",
            hostname: parsed.hostname,
            port: port,
            username: username,
            authMethod: .password,
            privateKeyPath: nil,
            keyID: nil,
            proxy: ProxyConfig(),
            jump: [],
            forwards: []
        )
        dismiss()
        onConnect(QuickConnectRequest(spec: spec, password: password.isEmpty ? nil : password))
    }
}
