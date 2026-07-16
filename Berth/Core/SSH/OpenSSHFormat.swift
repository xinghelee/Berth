import Crypto
import Foundation
import NIOCore

/// OpenSSH 公钥行(`ssh-ed25519 AAAA... comment`)的构造
enum OpenSSHFormat {

    static func publicKeyLine(ed25519 key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &blob)
        appendSSHString(key.rawRepresentation, to: &blob)
        return "ssh-ed25519 \(blob.base64EncodedString())\(comment.isEmpty ? "" : " \(comment)")"
    }

    /// 从 known_hosts 风格 blob 构造公钥行
    static func publicKeyLine(keyType: String, blob: Data, comment: String) -> String {
        "\(keyType) \(blob.base64EncodedString())\(comment.isEmpty ? "" : " \(comment)")"
    }

    /// prefix + 已按 SSH wire 格式编码的 key body → 完整公钥行
    static func publicKeyLine(prefix: String, keyBody: Data, comment: String) -> String {
        var blob = Data()
        appendSSHString(Data(prefix.utf8), to: &blob)
        blob.append(keyBody)
        return "\(prefix) \(blob.base64EncodedString())\(comment.isEmpty ? "" : " \(comment)")"
    }

    /// `ssh-copy-id` 等效命令:把公钥追加到远端 authorized_keys
    static func sshCopyIDCommand(publicKey: String, username: String, hostname: String, port: Int) -> String {
        let target = "\(username)@\(hostname)"
        let portArgument = port == 22 ? "" : " -p \(port)"
        return """
        echo '\(publicKey)' | ssh\(portArgument) \(target) 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
        """
    }

    private static func appendSSHString(_ data: Data, to blob: inout Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(data)
    }
}
