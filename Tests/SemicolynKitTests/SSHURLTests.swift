// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Core-tier coverage for `parseSSHURL` — equivalence partitions (host-only, user,
/// port, both, path, IPv6) + boundary values on the port, with negative cases
/// asserting the specific nil for each malformed class.
final class SSHURLTests: XCTestCase {
    // MARK: valid partitions

    func testHostOnly() {
        XCTAssertEqual(parseSSHURL("ssh://example.com"),
                       SSHConnectTarget(host: "example.com", user: nil, port: nil))
    }

    func testUserAndHost() {
        XCTAssertEqual(parseSSHURL("ssh://alice@example.com"),
                       SSHConnectTarget(host: "example.com", user: "alice", port: nil))
    }

    func testHostAndPort() {
        XCTAssertEqual(parseSSHURL("ssh://example.com:2222"),
                       SSHConnectTarget(host: "example.com", user: nil, port: 2222))
    }

    func testUserHostPort() {
        XCTAssertEqual(parseSSHURL("ssh://alice@example.com:2222"),
                       SSHConnectTarget(host: "example.com", user: "alice", port: 2222))
    }

    func testPathIsDropped() {
        XCTAssertEqual(parseSSHURL("ssh://alice@host:2222/some/path"),
                       SSHConnectTarget(host: "host", user: "alice", port: 2222))
    }

    func testSchemeIsCaseInsensitiveAndHostCasePreserved() {
        XCTAssertEqual(parseSSHURL("SSH://Host.Example"),
                       SSHConnectTarget(host: "Host.Example", user: nil, port: nil))
    }

    func testEmptyUserinfoYieldsNilUser() {
        XCTAssertEqual(parseSSHURL("ssh://@host"),
                       SSHConnectTarget(host: "host", user: nil, port: nil))
    }

    func testIPv6BracketedWithPort() {
        XCTAssertEqual(parseSSHURL("ssh://[::1]:22"),
                       SSHConnectTarget(host: "::1", user: nil, port: 22))
    }

    func testIPv6BracketedNoPort() {
        XCTAssertEqual(parseSSHURL("ssh://bob@[fe80::1]"),
                       SSHConnectTarget(host: "fe80::1", user: "bob", port: nil))
    }

    // MARK: port boundary values (valid 1…65535)

    func testPortLowBoundaryValid() {
        XCTAssertEqual(parseSSHURL("ssh://host:1")?.port, 1)
    }

    func testPortHighBoundaryValid() {
        XCTAssertEqual(parseSSHURL("ssh://host:65535")?.port, 65535)
    }

    // MARK: negative cases — each asserts the specific nil

    func testNonSSHSchemeIsNil() {
        XCTAssertNil(parseSSHURL("http://example.com"))
        XCTAssertNil(parseSSHURL("https://example.com"))
        XCTAssertNil(parseSSHURL("ftp://example.com"))
    }

    func testEmptyAndSchemeOnlyAreNil() {
        XCTAssertNil(parseSSHURL(""))
        XCTAssertNil(parseSSHURL("ssh://"))
    }

    func testEmptyHostIsNil() {
        XCTAssertNil(parseSSHURL("ssh://:22"))
        XCTAssertNil(parseSSHURL("ssh://user@:22"))
    }

    func testPortZeroIsNil() {
        XCTAssertNil(parseSSHURL("ssh://host:0"))
    }

    func testPortAboveMaxIsNil() {
        XCTAssertNil(parseSSHURL("ssh://host:65536"))
    }

    func testPortNonNumericIsNil() {
        XCTAssertNil(parseSSHURL("ssh://host:abc"))
    }

    func testTrailingColonWithoutPortIsNil() {
        XCTAssertNil(parseSSHURL("ssh://host:"))
    }
}
