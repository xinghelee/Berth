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
        // Citadel 的 Disconnected():TCP 已通但服务器在认证完成前关闭了连接。
        // 典型原因是源 IP 触发了服务器的连接频率限制(OpenSSH 9.8+ PerSourcePenalties / fail2ban)。
        if raw.contains("Disconnected") {
            return "服务器在握手阶段关闭了连接:多半是本机 IP 触发了 \(hostname) 的连接频率限制"
                + "(OpenSSH PerSourcePenalties 或 fail2ban)。请等待几分钟后再试,期间不要反复重连。"
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.localizedCaseInsensitiveContains("timeout") {
            return "连不上 \(hostname):\(port):连接超时,检查地址、防火墙或网络。"
        }
        if raw.localizedCaseInsensitiveContains("already closed")
            || raw.localizedCaseInsensitiveContains("connection reset")
            || raw.localizedCaseInsensitiveContains("eof") {
            return "连接已中断:与 \(hostname) 的会话被关闭。"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "连接失败:\(raw)"
    }
}
