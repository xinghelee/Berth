import Foundation
import Security

/// Keychain 封装:密码与 passphrase 只存 Keychain(kSecAttrAccessibleWhenUnlocked),
/// 数据库中不落任何明文,只按约定命名规则(host.<uuid>.password 等)引用。
enum KeychainStore {
    static let service = "com.berthssh.Berth"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(errSecAuthFailed):
                return "无法读取钥匙串中保存的密码(应用签名与保存时不一致,常见于开发构建更新后)。"
                    + "请编辑该主机并重新输入密码,保存后即可恢复。"
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain 操作失败:\(detail)"
            }
        }
    }

    // MARK: 账户命名约定

    static func passwordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).password" }
    static func passphraseAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).passphrase" }
    static func proxyPasswordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).proxyPassword" }

    // MARK: 基本操作

    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecAuthFailed {
            // 旧项的 ACL 绑定在别的构建上(如 ad-hoc 签名的历史版本),本构建无权更新。
            // 删掉重建:重新输入密码即可恢复,不让用户卡死在无法覆盖的旧项上。
            SecItemDelete(query as CFDictionary)
            status = errSecItemNotFound
        }
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 删除主机相关的全部凭据(删除主机时调用)
    static func deleteSecrets(for hostID: UUID) {
        try? delete(account: passwordAccount(for: hostID))
        try? delete(account: passphraseAccount(for: hostID))
    }
}
