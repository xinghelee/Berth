import SwiftUI

/// 主机密钥确认:首次连接展示指纹;密钥变更给出强警告 + 新旧指纹对比,
/// 必须显式确认,不允许静默接受(规格 5.3 安全关键)。
struct HostKeyPromptSheet: View {
    let prompt: HostKeyPrompt
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: prompt.isKeyChange ? "exclamationmark.triangle.fill" : "key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(prompt.isKeyChange ? .red : .accentColor)
                Text(prompt.isKeyChange ? "主机密钥已变更!" : "首次连接此主机")
                    .font(.title3.bold())
            }

            if prompt.isKeyChange {
                Text("\(prompt.hostname):\(String(prompt.port)) 返回的主机密钥与 known_hosts 中的记录不一致。这可能意味着中间人攻击,也可能是服务器重装或更换了密钥。请先向服务器管理员核实,再决定是否继续。")
                    .font(.callout)
            } else {
                Text("无法验证 \(prompt.hostname):\(String(prompt.port)) 的真实性。请核对下方指纹与服务器提供方公布的一致后再继续。")
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("密钥类型", value: prompt.keyType)
                LabeledContent("指纹") {
                    Text(prompt.fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                if prompt.isKeyChange {
                    LabeledContent("原记录指纹") {
                        VStack(alignment: .leading) {
                            ForEach(prompt.knownFingerprints, id: \.self) { fingerprint in
                                Text(fingerprint)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            HStack {
                Button("取消连接") {
                    session.resolveHostKeyPrompt(accepted: false)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if prompt.isKeyChange {
                    Button(role: .destructive) {
                        session.resolveHostKeyPrompt(accepted: true)
                    } label: {
                        Text("我已核实,更新并连接")
                    }
                } else {
                    Button("信任并连接") {
                        session.resolveHostKeyPrompt(accepted: true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
