import Foundation

/// 连接错误的人话化(M1 基础版,M2 按规格 5.3 覆盖更多场景)
enum SSHErrorMapper {
    static func friendlyMessage(
        for error: Error,
        hostname: String,
        port: Int,
        authMethod: AuthMethodKind? = nil
    ) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("allAuthenticationOptionsFailed")
            || raw.localizedCaseInsensitiveContains("authentication") {
            // 按认证方式给针对性排查提示
            switch authMethod {
            case .password:
                return String(localized: "认证失败:密码不正确,或服务器没有开放该用户的密码登录。")
            case .privateKeyFile, .storedKey, .agent:
                return String(localized: "认证失败:服务器不接受这把密钥。请确认公钥已加入服务器上该用户的 ~/.ssh/authorized_keys,且用户名无误。")
            case nil:
                return String(localized: "认证失败:服务器拒绝了用户名、密码或密钥。")
            }
        }
        if raw.localizedCaseInsensitiveContains("refused") {
            return String(localized: "连不上 \(hostname):\(String(port)):连接被拒绝,检查端口号和 sshd 是否在运行。")
        }
        // Citadel 的 Disconnected():TCP 已通但服务器在认证完成前关闭了连接。
        // 典型原因是源 IP 触发了服务器的连接频率限制(OpenSSH 9.8+ PerSourcePenalties / fail2ban)。
        if raw.contains("Disconnected") {
            return String(localized: "服务器在握手阶段关闭了连接:多半是本机 IP 触发了 \(hostname) 的连接频率限制")
                + String(localized: "(OpenSSH PerSourcePenalties 或 fail2ban)。请等待几分钟后再试,期间不要反复重连。")
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.localizedCaseInsensitiveContains("timeout") {
            return String(localized: "连不上 \(hostname):\(String(port)):连接超时,检查地址、防火墙或网络。")
        }
        if raw.localizedCaseInsensitiveContains("already closed")
            || raw.localizedCaseInsensitiveContains("connection reset")
            || raw.localizedCaseInsensitiveContains("eof") {
            return String(localized: "连接已中断:与 \(hostname) 的会话被关闭。")
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(localized: "连接失败:\(raw)")
    }
}
