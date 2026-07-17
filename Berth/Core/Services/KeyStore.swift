import Crypto
import Citadel
import Foundation
import NIOCore
import SwiftData

/// 密钥库操作:生成 / 导入 / 删除。私钥材料只进 Keychain。
@MainActor
enum KeyStore {

    enum KeyStoreError: LocalizedError {
        case unsupportedKey
        case emptyName

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return String(localized: "无法解析密钥:支持 OpenSSH 格式的 ed25519 / RSA 私钥;若有 passphrase 请一并填写。")
            case .emptyName:
                return String(localized: "给密钥起个名字。")
            }
        }
    }

    @discardableResult
    static func generateEd25519(name: String, context: ModelContext) throws -> SSHKeyRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw KeyStoreError.emptyName }

        let privateKey = Curve25519.Signing.PrivateKey()
        let comment = "\(NSUserName())@Berth"
        let publicLine = OpenSSHFormat.publicKeyLine(ed25519: privateKey.publicKey, comment: comment)

        let record = SSHKeyRecord(name: trimmedName, keyType: "ssh-ed25519", publicKey: publicLine, storageFormat: .rawEd25519)
        try KeychainStore.save(
            privateKey.rawRepresentation.base64EncodedString(),
            account: KeychainStore.privateKeyAccount(for: record.id)
        )
        context.insert(record)
        try context.save()
        return record
    }

    @discardableResult
    static func importKey(name: String, pemText: String, passphrase: String?, context: ModelContext) throws -> SSHKeyRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw KeyStoreError.emptyName }
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

        let keyType: String
        let publicLine: String

        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pemText, decryptionKey: decryptionKey) {
            keyType = "ssh-ed25519"
            publicLine = OpenSSHFormat.publicKeyLine(ed25519: key.publicKey, comment: trimmedName)
        } else if let key = try? Insecure.RSA.PrivateKey(sshRsa: pemText, decryptionKey: decryptionKey) {
            keyType = "ssh-rsa"
            var body = ByteBufferAllocator().buffer(capacity: 1024)
            _ = key.publicKey.write(to: &body)
            publicLine = OpenSSHFormat.publicKeyLine(
                prefix: "ssh-rsa",
                keyBody: Data(body.readableBytesView),
                comment: trimmedName
            )
        } else {
            throw KeyStoreError.unsupportedKey
        }

        let record = SSHKeyRecord(name: trimmedName, keyType: keyType, publicKey: publicLine, storageFormat: .opensshPEM)
        try KeychainStore.save(pemText, account: KeychainStore.privateKeyAccount(for: record.id))
        if let passphrase, !passphrase.isEmpty {
            try KeychainStore.save(passphrase, account: KeychainStore.keyPassphraseAccount(for: record.id))
        }
        context.insert(record)
        try context.save()
        return record
    }

    static func delete(_ record: SSHKeyRecord, context: ModelContext) {
        KeychainStore.deleteSecrets(forKey: record.id)
        context.delete(record)
        try? context.save()
    }

    /// 使用该密钥的主机数(删除前提示)
    static func hostsUsing(keyID: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.keyID == keyID })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
