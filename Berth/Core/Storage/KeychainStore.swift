import Foundation
import Security

/// Keychain 封装:密码与 passphrase 只存 Keychain(数据库不落明文,按约定命名引用)。
///
/// 跨设备直连的关键三要素:
/// 1. **共享访问组** `<TeamID>.com.berthssh.shared`:Mac(com.berthssh.app)与 iOS
///    (com.berthssh.ios)bundle id 不同,默认访问组也不同,互相读不到对方写的项。
///    两端 entitlement 都声明同一个 keychain-access-group,才能共享。
/// 2. **数据保护钥匙串** `kSecUseDataProtectionKeychain`:macOS 默认用老式文件钥匙串,
///    不进 iCloud 同步也不支持访问组;显式切到 iOS 同款数据保护钥匙串。
/// 3. **可同步** `kSecAttrSynchronizable`:经 iCloud 钥匙串端到端加密同步。Berth 无自有服务器。
enum KeychainStore {
    static let service = "com.berthssh.app"
    /// 与 project.yml 里两端 entitlement 的 `$(AppIdentifierPrefix)com.berthssh.shared` 一致
    static let accessGroup = "99LYH6FNPS.com.berthssh.shared"

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

    /// 共享组 + 数据保护 + 可同步的基础查询;`sync` 传 SynchronizableAny 供读/删跨同步态匹配
    private static func baseQuery(account: String, syncAny: Bool = false) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: syncAny ? kSecAttrSynchronizableAny : true,
        ]
    }

    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecAuthFailed || status == errSecItemNotFound {
            // 覆盖历史遗留(本机-only 旧项,或 ACL 绑定在别的构建上的项):删掉重建
            SecItemDelete(baseQuery(account: account, syncAny: true) as CFDictionary)
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func read(account: String) throws -> String? {
        var query = baseQuery(account: account, syncAny: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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
        let status = SecItemDelete(baseQuery(account: account, syncAny: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 一次性迁移:把旧位置(新旧 service 名 × 文件/数据保护钥匙串)里的机密,
    /// 搬进共享组的数据保护钥匙串并可同步。之后同一 Apple ID 的两端可直连。
    /// 出错(钥匙串被锁等)时不打完成标记,下次启动重试。
    static func migrateToSharedGroupIfNeeded() {
        let flag = "migration.keychainSharedGroup.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        var collected: [String: String] = [:]

        /// 单条取密文(旧项 ACL 绑在老签名上,首次读可能触发钥匙串授权弹窗,选"始终允许"即可)
        func readLegacy(account: String, service svc: String, dataProtection: Bool) -> String? {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            q[kSecUseDataProtectionKeychain as String] = dataProtection
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        /// 两段式:文件钥匙串不支持 MatchLimitAll+返回 data,先取账户名再逐条读密文
        func harvest(service svc: String, dataProtection: Bool) -> Bool {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            query[kSecUseDataProtectionKeychain as String] = dataProtection
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                return status == errSecItemNotFound
            }
            for item in items {
                // 只搬 Berth 约定账户:host.<uuid>.* 密码 / key.<uuid>.* 私钥口令
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix("host.") || account.hasPrefix("key."),
                      collected[account] == nil,
                      let secret = readLegacy(account: account, service: svc, dataProtection: dataProtection)
                else { continue }
                collected[account] = secret
            }
            return true
        }

        var ok = true
        for svc in [service] {
            #if os(macOS)
            ok = harvest(service: svc, dataProtection: false) && ok
            ok = harvest(service: svc, dataProtection: true) && ok
            #else
            ok = harvest(service: svc, dataProtection: true) && ok
            #endif
        }

        for (account, secret) in collected {
            try? save(secret, account: account)
        }
        if ok {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    /// 删除主机相关的全部凭据(删除主机时调用)
    static func deleteSecrets(for hostID: UUID) {
        try? delete(account: passwordAccount(for: hostID))
        try? delete(account: passphraseAccount(for: hostID))
    }
}
