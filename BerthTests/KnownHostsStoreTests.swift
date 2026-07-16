import XCTest
@testable import Berth

final class KnownHostsStoreTests: XCTestCase {

    func testParsePlainLine() throws {
        let entry = try XCTUnwrap(KnownHostsStore.parseLine(
            "example.com,10.0.0.5 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6D7NYebj0o5DHPnogerk0ye4T0H4HB8zJbTfxQ+Mpe"
        ))
        XCTAssertEqual(entry.hostPatterns, ["example.com", "10.0.0.5"])
        XCTAssertEqual(entry.keyType, "ssh-ed25519")
        XCTAssertNil(entry.hashedPattern)
    }

    func testParseSkipsCommentsAndMarkers() {
        XCTAssertNil(KnownHostsStore.parseLine("# comment"))
        XCTAssertNil(KnownHostsStore.parseLine(""))
        XCTAssertNil(KnownHostsStore.parseLine("@revoked example.com ssh-ed25519 AAAA"))
    }

    func testHostTokenFormat() {
        XCTAssertEqual(KnownHostsStore.hostToken(hostname: "example.com", port: 22), "example.com")
        XCTAssertEqual(KnownHostsStore.hostToken(hostname: "example.com", port: 2222), "[example.com]:2222")
    }

    func testEntryMatchingWithWildcardAndNegation() throws {
        let entry = try XCTUnwrap(KnownHostsStore.parseLine("*.example.com,!bad.example.com ssh-ed25519 AAAA"))
        XCTAssertTrue(KnownHostsStore.entryMatches(entry, hostToken: "web.example.com"))
        XCTAssertFalse(KnownHostsStore.entryMatches(entry, hostToken: "bad.example.com"))
        XCTAssertFalse(KnownHostsStore.entryMatches(entry, hostToken: "other.org"))
    }

    func testHashedEntryMatching() throws {
        // 用 ssh-keyscan/OpenSSH 相同算法构造:HMAC-SHA1(salt, host)
        // 这里直接验证我们自己的实现自洽(salt 随机,hash 由实现计算)
        let host = "[127.0.0.1]:2222"
        let salt = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let mac = try hmacSHA1(key: salt, message: Data(host.utf8))
        let line = "|1|\(salt.base64EncodedString())|\(mac.base64EncodedString()) ssh-ed25519 AAAA"
        let entry = try XCTUnwrap(KnownHostsStore.parseLine(line))
        XCTAssertTrue(KnownHostsStore.entryMatches(entry, hostToken: host))
        XCTAssertFalse(KnownHostsStore.entryMatches(entry, hostToken: "other.example.com"))
    }

    func testAppendEvaluateReplaceRoundtrip() throws {
        let directory = NSTemporaryDirectory() + "berth-test-\(UUID().uuidString)"
        let path = directory + "/known_hosts"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = KnownHostsStore(path: path)

        // 造两把真实 ed25519 公钥
        let keyA = try NIOSSHPublicKeyFixture.random()
        let keyB = try NIOSSHPublicKeyFixture.random()

        XCTAssertEqual(store.evaluate(hostname: "test.local", port: 2200, presentedKey: keyA), .unknown)

        try store.append(hostname: "test.local", port: 2200, key: keyA)
        XCTAssertEqual(store.evaluate(hostname: "test.local", port: 2200, presentedKey: keyA), .trusted)
        // 同主机不同端口视为不同记录
        XCTAssertEqual(store.evaluate(hostname: "test.local", port: 22, presentedKey: keyA), .unknown)

        // 换了密钥 → mismatch,且给出旧指纹
        if case .mismatch(let known) = store.evaluate(hostname: "test.local", port: 2200, presentedKey: keyB) {
            XCTAssertEqual(known, [KnownHostsStore.fingerprint(of: keyA)])
        } else {
            XCTFail("expected mismatch")
        }

        // 显式确认后替换 → 新密钥 trusted,旧密钥 mismatch
        try store.replace(hostname: "test.local", port: 2200, key: keyB)
        XCTAssertEqual(store.evaluate(hostname: "test.local", port: 2200, presentedKey: keyB), .trusted)
        if case .mismatch = store.evaluate(hostname: "test.local", port: 2200, presentedKey: keyA) {} else {
            XCTFail("old key should mismatch after replace")
        }
    }

    func testFingerprintFormat() throws {
        let key = try NIOSSHPublicKeyFixture.random()
        let fingerprint = KnownHostsStore.fingerprint(of: key)
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(fingerprint.hasSuffix("="))
    }

    private func hmacSHA1(key: Data, message: Data) throws -> Data {
        // 与实现相同的算法路径,但独立走 CryptoKit 以互证
        var hmac = TestHMACSHA1(key: key)
        return hmac.compute(message: message)
    }
}

// MARK: - 辅助

import Crypto
import NIOSSH

enum NIOSSHPublicKeyFixture {
    /// 生成随机 ed25519 公钥(openssh 格式往返)
    static func random() throws -> NIOSSHPublicKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let blob = ed25519PublicKeyBlob(privateKey.publicKey)
        let line = "ssh-ed25519 \(blob.base64EncodedString()) test"
        return try NIOSSHPublicKey(openSSHPublicKey: line)
    }

    private static func ed25519PublicKeyBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var data = Data()
        func appendString(_ string: Data) {
            var length = UInt32(string.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(string)
        }
        appendString(Data("ssh-ed25519".utf8))
        appendString(key.rawRepresentation)
        return data
    }
}

struct TestHMACSHA1 {
    let key: Data

    mutating func compute(message: Data) -> Data {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }
}
