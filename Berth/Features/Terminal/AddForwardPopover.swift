import SwiftUI

/// 临时端口转发的输入 popover:选类型 + 填端口/目标,确认后交给会话即时建立(不落库)。
struct AddForwardPopover: View {
    let onAdd: (PortForwardSpec) -> Void

    @State private var kind: PortForwardKind = .local
    @State private var bindPort = ""
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = ""
    @State private var error: String?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("临时端口转发")
                .font(.headline)

            Picker("类型", selection: $kind) {
                Text("本地 (-L)").tag(PortForwardKind.local)
                Text("远程 (-R)").tag(PortForwardKind.remote)
                Text("动态 SOCKS5 (-D)").tag(PortForwardKind.dynamic)
            }
            .pickerStyle(.segmented)

            HStack {
                TextField(kind == .remote ? "远端端口" : "本地端口", text: $bindPort)
                    .frame(width: 90)
                if kind != .dynamic {
                    Text("→").foregroundStyle(.secondary)
                    TextField("目标主机", text: $targetHost)
                    TextField("端口", text: $targetPort)
                        .frame(width: 70)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))

            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("建立") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(theme.accentColor)
    }

    private var hint: String {
        switch kind {
        case .local: return String(localized: "把本地端口转到远端目标(如本地 8080 → 远端 127.0.0.1:80)。")
        case .remote: return String(localized: "把远端端口转回本地目标(如远端 8080 → 本地 127.0.0.1:3000)。")
        case .dynamic: return String(localized: "在本地开一个 SOCKS5 代理端口,经此服务器出网。")
        }
    }

    private func submit() {
        guard let bind = Int(bindPort), (1...65535).contains(bind) else {
            error = String(localized: "端口需要是 1-65535 之间的数字。")
            return
        }
        var target = "127.0.0.1"
        var tPort = 0
        if kind != .dynamic {
            guard let tp = Int(targetPort), (1...65535).contains(tp) else {
                error = String(localized: "目标端口需要是 1-65535 之间的数字。")
                return
            }
            target = targetHost.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : targetHost
            tPort = tp
        }
        let spec = PortForwardSpec(
            kind: kind,
            bindHost: "127.0.0.1",
            bindPort: bind,
            targetHost: target,
            targetPort: tPort
        )
        onAdd(spec)
    }
}
