// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: a missed secret value here is a leaked credential, so every
/// flag form is an adversarial negative asserting the SPECIFIC dropped index.
final class SecretArgDenylistTests: XCTestCase {
    /// Convenience: which tokens survive after dropping the denylisted indexes.
    private func surviving(_ tokens: [String]) -> [String] {
        let drop = secretValueIndexes(in: tokens)
        return tokens.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    func testSpaceSeparatedPasswordFlagDropsValue() {
        XCTAssertEqual(surviving(["mysql", "-p", "hunter2"]), ["mysql", "-p"])
    }

    func testEqualsJoinedTokenFlagDropsWholeToken() {
        XCTAssertEqual(surviving(["curl", "--token=ghp_x"]), ["curl"])
    }

    func testLongPasswordFlagDropsValue() {
        XCTAssertEqual(surviving(["app", "--password", "s3cret"]), ["app", "--password"])
    }

    func testFlagMatchIsCaseInsensitive() {
        XCTAssertEqual(surviving(["app", "--Token", "abc"]), ["app", "--Token"])
        XCTAssertEqual(surviving(["app", "--TOKEN=abc"]), ["app"])
    }

    func testAuthorizationHeaderDropsFollowingToken() {
        // Conservative: drop the single token after the header token.
        XCTAssertEqual(surviving(["curl", "Authorization:", "sekret"]), ["curl", "Authorization:"])
    }

    func testUserPassAtHostDropsWholeToken() {
        XCTAssertEqual(surviving(["ssh", "alice:pw@host"]), ["ssh"])
    }

    func testPlainCommandDropsNothing() {
        XCTAssertEqual(surviving(["git", "commit", "-m", "msg"]), ["git", "commit", "-m", "msg"])
    }

    func testFlagAtEndOfLineWithNoValueDropsNothingExtra() {
        // "--token" with no following token: nothing to drop (no crash / no over-reach).
        XCTAssertEqual(surviving(["curl", "--token"]), ["curl", "--token"])
    }

    func testShortDashPUpperAndLower() {
        XCTAssertEqual(surviving(["x", "-p", "a"]), ["x", "-p"])
        XCTAssertEqual(surviving(["x", "-P", "a"]), ["x", "-P"])
    }

    func testIncrementalSecretValuePredicate() {
        XCTAssertTrue(isSecretValueToken("hunter2", precededBy: "-p"))
        XCTAssertTrue(isSecretValueToken("--token=x", precededBy: "curl"))
        XCTAssertTrue(isSecretValueToken("alice:pw@host", precededBy: "ssh"))
        XCTAssertTrue(isSecretValueToken("sekret", precededBy: "Authorization:"))
        XCTAssertFalse(isSecretValueToken("commit", precededBy: "git"))
        XCTAssertFalse(isSecretValueToken("--token", precededBy: "curl"))   // the flag itself is not a value
    }
}
