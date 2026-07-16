import XCTest
@testable import Berth

final class SSHCommandParserTests: XCTestCase {

    func testBareUserHost() {
        XCTAssertEqual(
            SSHCommandParser.parse("dev@example.com"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: nil)
        )
    }

    func testUserHostPort() {
        XCTAssertEqual(
            SSHCommandParser.parse("dev@example.com:2222"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: 2222)
        )
    }

    func testHostOnly() {
        XCTAssertEqual(
            SSHCommandParser.parse("example.com"),
            ParsedSSHTarget(username: nil, hostname: "example.com", port: nil)
        )
    }

    func testHostPortOnly() {
        XCTAssertEqual(
            SSHCommandParser.parse("10.0.0.5:2200"),
            ParsedSSHTarget(username: nil, hostname: "10.0.0.5", port: 2200)
        )
    }

    func testBracketedIPv6WithPort() {
        XCTAssertEqual(
            SSHCommandParser.parse("root@[::1]:2222"),
            ParsedSSHTarget(username: "root", hostname: "::1", port: 2222)
        )
    }

    func testBareIPv6NotSplitOnColons() {
        XCTAssertEqual(
            SSHCommandParser.parse("fe80::1"),
            ParsedSSHTarget(username: nil, hostname: "fe80::1", port: nil)
        )
    }

    func testSSHCommandWithPortFlag() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh dev@example.com -p 2222"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: 2222)
        )
    }

    func testSSHCommandFlagsBeforeDestination() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh -p 2222 -i ~/.ssh/prod_key dev@example.com"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: 2222, identityFile: "~/.ssh/prod_key")
        )
    }

    func testSSHCommandLoginNameFlag() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh -l dev example.com"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: nil)
        )
    }

    func testUserAtHostBeatsLoginFlag() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh -l other dev@example.com")?.username,
            "dev"
        )
    }

    func testSSHURLForm() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh ssh://dev@example.com:2200/"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: 2200)
        )
    }

    func testRemoteCommandIgnored() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh dev@example.com uptime"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: nil)
        )
    }

    func testOptionWithArgumentSkipped() {
        XCTAssertEqual(
            SSHCommandParser.parse("ssh -o StrictHostKeyChecking=no dev@example.com"),
            ParsedSSHTarget(username: "dev", hostname: "example.com", port: nil)
        )
    }

    func testInvalidInputs() {
        XCTAssertNil(SSHCommandParser.parse(""))
        XCTAssertNil(SSHCommandParser.parse("   "))
        XCTAssertNil(SSHCommandParser.parse("@example.com"))
        XCTAssertNil(SSHCommandParser.parse("dev@"))
        XCTAssertNil(SSHCommandParser.parse("host:99999"))
        XCTAssertNil(SSHCommandParser.parse("ssh"))
        XCTAssertNil(SSHCommandParser.parse("ssh -p"))
    }
}
