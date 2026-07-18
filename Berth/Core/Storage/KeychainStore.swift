import Foundation
import Security

/// Keychain 封装:密码与 passphrase 只存 Keychain(kSecAttrAccessibleWhenUnlocked),
/// 数据库中不落任何明文,只按约定命名规则(host.<uuid>.password 等)引用。
enum KeychainStore {
    static let service = "com.berthssh.app"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(errSecAuthFailed):
                return String(localized: "无法读取钥匙串中保存的密码(应用签名与保存时不一致,常见于开发构建更新后)。")
                    + String(localized: "请编辑该主机并重新输入密码,保存后即可恢复。")
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return String(localized: "Keychain 操作失败:\(detail)")
            }
        }
    }

    // MARK: 账户命名约定

    static func passwordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).password" }
    static func passphraseAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).passphrase" }
    static func proxyPasswordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).proxyPassword" }

    // MARK: 基本操作

    /// 机密项统一走 iCloud 钥匙串同步(kSecAttrSynchronizable,端到端加密):
    /// 任一设备录入一次,同一 Apple ID 的其它设备可直接连接。Berth 无自有服务器。
    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecAuthFailed || status == errSecItemNotFound {
            // 覆盖历史遗留:本机-only 旧项,或 ACL 绑定在别的构建上的项——删除后按可同步项重建
            let purge: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            SecItemDelete(purge as CFDictionary)
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 一次性迁移:把本机-only 的旧机密项重写为可同步项(iCloud 钥匙串)。
    /// 出错(如钥匙串被锁)时不打完成标记,下次启动重试。
    static func migrateToSynchronizableIfNeeded() {
        let flag = "migration.keychainSynchronizable.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let secret = String(data: data, encoding: .utf8) else { continue }
                try? save(secret, account: account)
            }
        }
        if status == errSecSuccess || status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    /// 删除主机相关的全部凭据(删除主机时调用)
    static func deleteSecrets(for hostID: UUID) {
        try? delete(account: passwordAccount(for: hostID))
        try? delete(account: passphraseAccount(for: hostID))
    }
}
