import Foundation
import SwiftData

/// 密钥库中的一把密钥。私钥内容只存 Keychain:
/// - 生成的 ed25519:存 rawRepresentation(base64),storageFormat = rawEd25519
/// - 导入的 OpenSSH PEM:存原文(连接时用 passphrase 解析),storageFormat = opensshPEM
enum SSHKeyStorageFormat: String, Codable {
    case rawEd25519
    case opensshPEM
}

@Model
final class SSHKeyRecord {
    var id: UUID = UUID()
    var name: String = ""
    var keyType: String = ""   // ssh-ed25519 / ssh-rsa …
    var publicKey: String = "" // openssh 单行公钥
    var storageFormatRaw: String = SSHKeyStorageFormat.opensshPEM.rawValue
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, keyType: String, publicKey: String, storageFormat: SSHKeyStorageFormat) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
        self.storageFormatRaw = storageFormat.rawValue
        self.createdAt = Date()
    }

    var storageFormat: SSHKeyStorageFormat {
        SSHKeyStorageFormat(rawValue: storageFormatRaw) ?? .opensshPEM
    }
}

extension KeychainStore {
    static func privateKeyAccount(for keyID: UUID) -> String { "key.\(keyID.uuidString).privateKey" }
    static func keyPassphraseAccount(for keyID: UUID) -> String { "key.\(keyID.uuidString).passphrase" }

    static func deleteSecrets(forKey keyID: UUID) {
        try? delete(account: privateKeyAccount(for: keyID))
        try? delete(account: keyPassphraseAccount(for: keyID))
    }
}
