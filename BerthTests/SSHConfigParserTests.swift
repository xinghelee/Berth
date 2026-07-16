import XCTest
@testable import Berth

final class SSHConfigParserTests: XCTestCase {

    func testBasicBlock() {
        let config = """
        Host web
            HostName web.example.com
            User deploy
            Port 2200
        """
        let hosts = SSHConfigParser.parse(config, homeDirectory: "/Users/tester")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "web")
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 2200)
    }

    func testHostnameDefaultsToAlias() {
        let hosts = SSHConfigParser.parse("Host bare.example.com\n  User root")
        XCTAssertEqual(hosts[0].hostname, "bare.example.com")
    }

    func testMultipleAliasesInOneHostLine() {
        let config = """
        Host web api
            HostName shared.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web", "api"])
        XCTAssertEqual(hosts[0].hostname, "shared.example.com")
        XCTAssertEqual(hosts[1].hostname, "shared.example.com")
    }

    func testWildcardBlockAppliesButIsNotListed() {
        let config = """
        Host *
            User fallback
            Port 2222
        Host web
            HostName web.example.com
            Port 22
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web"])
        XCTAssertEqual(hosts[0].user, "fallback")
        // ssh 语义:第一次出现的值生效 —— Host * 在前,Port 取 2222
        XCTAssertEqual(hosts[0].port, 2222)
    }

    func testFirstObtainedValueWins() {
        let config = """
        Host web
            HostName first.example.com
        Host web
            HostName second.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "first.example.com")
    }

    func testNegatedPatternExcludesBlock() {
        let config = """
        Host * !web
            User fallback
        Host web
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertNil(hosts[0].user)
    }

    func testIdentityFileTildeExpansion() {
        let config = """
        Host web
            IdentityFile ~/.ssh/prod_key
        """
        let hosts = SSHConfigParser.parse(config, homeDirectory: "/Users/tester")
        XCTAssertEqual(hosts[0].identityFile, "/Users/tester/.ssh/prod_key")
    }

    func testProxyJump() {
        let config = """
        Host internal
            HostName 10.0.0.8
            ProxyJump bastion.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].proxyJump, "bastion.example.com")
    }

    func testGlobalOptionsBeforeAnyHostActAsWildcard() {
        let config = """
        User global
        Host web
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].user, "global")
    }

    func testMatchBlockSkipped() {
        let config = """
        Host web
            HostName web.example.com
        Match user deploy
            Port 9999
        Host api
            HostName api.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web", "api"])
        XCTAssertNil(hosts[0].port)
        XCTAssertNil(hosts[1].port)
    }

    func testCommentsAndEqualsSyntax() {
        let config = """
        # 生产环境
        Host web
            HostName=web.example.com
            User = deploy
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
    }

    func testQuotedValue() {
        let config = """
        Host web
            IdentityFile "/Users/tester/my keys/prod"
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].identityFile, "/Users/tester/my keys/prod")
    }

    func testWildcardMatching() {
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web-1", pattern: "web-*"))
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web", pattern: "*"))
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web1", pattern: "web?"))
        XCTAssertFalse(SSHConfigParser.wildcardMatch("web12", pattern: "web?"))
        XCTAssertFalse(SSHConfigParser.wildcardMatch("api", pattern: "web*"))
    }
}

final class KeychainStoreTests: XCTestCase {

    func testRoundtripAndDelete() throws {
        let account = "unittest.\(UUID().uuidString)"
        try KeychainStore.save("secret-1", account: account)
        XCTAssertEqual(try KeychainStore.read(account: account), "secret-1")

        // 覆盖更新
        try KeychainStore.save("secret-2", account: account)
        XCTAssertEqual(try KeychainStore.read(account: account), "secret-2")

        try KeychainStore.delete(account: account)
        XCTAssertNil(try KeychainStore.read(account: account))

        // 删除不存在的账户不应抛错
        XCTAssertNoThrow(try KeychainStore.delete(account: account))
    }
}
