import Foundation

/// 连接错误的人话化(M1 基础版,M2 按规格 5.3 覆盖更多场景)
enum SSHErrorMapper {
    static func friendlyMessage(for error: Error, hostname: String, port: Int) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("allAuthenticationOptionsFailed")
            || raw.localizedCaseInsensitiveContains("authentication") {
            return "服务器拒绝了认证:检查用户名、密码或密钥是否正确(公钥是否已加入 authorized_keys)。"
        }
        if raw.localizedCaseInsensitiveContains("refused") {
            return "连不上 \(hostname):\(port):连接被拒绝,检查端口号和 sshd 是否在运行。"
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.localizedCaseInsensitiveContains("timeout") {
            return "连不上 \(hostname):\(port):连接超时,检查地址、防火墙或网络。"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "连接失败:\(raw)"
    }
}
