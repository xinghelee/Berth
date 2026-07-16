import SwiftData
import SwiftUI

/// ⌘K 临时直连:补齐凭据后连接,可选保存为主机(默认勾选)。
struct DirectConnectSheet: View {
    let request: DirectConnectRequest

    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var authMethod: AuthMethodKind = .password
    @State private var password = ""
    @State private var privateKeyPath = ""
    @State private var passphrase = ""
    @State private var saveAsHost = true
    @State private var label = ""

    private var target: ParsedSSHTarget { request.target }
    private var address: String {
        "\(target.username ?? "")@\(target.hostname)\(target.port.map { ":\($0)" } ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("目标", value: address)
                }
                Section("认证") {
                    Picker("认证方式", selection: $authMethod) {
                        Text("密码").tag(AuthMethodKind.password)
                        Text("私钥文件").tag(AuthMethodKind.privateKeyFile)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .password {
                        SecureField("密码", text: $password)
                    } else {
                        TextField("私钥路径", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                        SecureField("Passphrase(没有则不填)", text: $passphrase)
                    }
                }
                Section {
                    Toggle("保存为主机", isOn: $saveAsHost)
                    if saveAsHost {
                        TextField("显示名", text: $label, prompt: Text(target.hostname))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("连接") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 420, height: 360)
        .onAppear {
            if let identityFile = target.identityFile {
                authMethod = .privateKeyFile
                privateKeyPath = identityFile
            }
        }
    }

    private func connect() {
        let username = target.username ?? NSUserName()
        let port = target.port ?? 22

        if saveAsHost {
            let displayLabel = label.trimmingCharacters(in: .whitespaces)
            let host = Host(
                label: displayLabel.isEmpty ? target.hostname : displayLabel,
                hostname: target.hostname,
                port: port,
                username: username,
                authMethod: authMethod,
                privateKeyPath: authMethod == .privateKeyFile ? privateKeyPath : nil
            )
            host.lastConnectedAt = Date()
            modelContext.insert(host)
            if authMethod == .password, !password.isEmpty {
                try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: host.id))
            }
            if authMethod == .privateKeyFile, !passphrase.isEmpty {
                try? KeychainStore.save(passphrase, account: KeychainStore.passphraseAccount(for: host.id))
            }
            try? modelContext.save()
            sessionManager.open(spec: HostSpec(host: host))
        } else {
            let spec = HostSpec(
                hostID: UUID(),
                label: target.hostname,
                hostname: target.hostname,
                port: port,
                username: username,
                authMethod: authMethod,
                privateKeyPath: authMethod == .privateKeyFile ? privateKeyPath : nil
            )
            sessionManager.open(
                spec: spec,
                transientPassword: authMethod == .password ? password : nil,
                transientPassphrase: authMethod == .privateKeyFile && !passphrase.isEmpty ? passphrase : nil
            )
        }
        dismiss()
    }
}
