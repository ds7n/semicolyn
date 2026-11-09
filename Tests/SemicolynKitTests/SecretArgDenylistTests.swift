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

    // MARK: P-M6 part 1 gaps. Each case runs through BOTH public APIs.

    /// Indexes dropped by the streaming predicate, folding the tracker's rule that the
    /// token after a scheme word dropped as a header's value is the credential.
    private func streamingDropped(_ tokens: [String]) -> Set<Int> {
        var drop: Set<Int> = []
        var prev: String?
        var credentialPending = false
        for (i, t) in tokens.enumerated() {
            let pending = credentialPending
            credentialPending = false
            if pending || isSecretValueToken(t, precededBy: prev) {
                drop.insert(i)
                credentialPending = !pending && isAuthScheme(t) && (prev.map(isSecretHeaderToken) ?? false)
                prev = nil
            } else {
                prev = t
            }
        }
        return drop
    }

    private func assertDrops(_ tokens: [String], _ expected: Set<Int>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(secretValueIndexes(in: tokens), expected, "array API", file: file, line: line)
        XCTAssertEqual(streamingDropped(tokens), expected, "streaming API", file: file, line: line)
    }

    func testJoinedShortPasswordDropsToken() { assertDrops(["mysql", "-psecret"], [1]) }

    func testJoinedUppercasePortFlagIsNotAPassword() {
        assertDrops(["mysql", "-P3306"], [])
    }

    /// The pre-existing rule (`testShortDashPUpperAndLower`) still drops the value
    /// after a bare `-P` (over-suppression kept, not loosened).
    func testSpaceSeparatedUppercaseDashPKeepsExistingDrop() {
        assertDrops(["mysql", "-P", "3306"], [2])
    }

    func testBareDashPKeepsFollowingValueBehavior() { assertDrops(["mysql", "-p", "hunter2"], [2]) }

    func testUserColonPasswordValueDropped() { assertDrops(["curl", "-u", "user:pass"], [2]) }

    func testUserWithoutColonKept() { assertDrops(["curl", "-u", "alice"], []) }

    func testLongUserFlagValueWithColonDropped() { assertDrops(["curl", "--user", "a:b"], [2]) }

    func testJoinedUserEqualsColonDropped() { assertDrops(["curl", "--user=a:b"], [1]) }

    func testJoinedUserEqualsWithoutColonKept() { assertDrops(["curl", "--user=alice"], []) }

    func testJoinedShortUserColonDropped() { assertDrops(["curl", "-ualice:pw"], [1]) }

    func testQuotedAuthorizationBearerDropsSchemeAndCredential() {
        assertDrops(["curl", "-H", "'Authorization:", "Bearer", "abc'"], [3, 4])
        assertDrops(["curl", "-H", "\"Authorization:", "Bearer", "abc\""], [3, 4])
    }

    func testUnquotedAuthorizationBearerDropsSchemeAndCredential() {
        assertDrops(["curl", "-H", "Authorization:", "Bearer", "abc"], [3, 4])
    }

    func testQuotedApiKeyHeaderDropsValue() {
        assertDrops(["curl", "-H", "'X-API-Key:", "abc'"], [3])
    }

    func testExportedSecretNamedAssignmentDropped() {
        assertDrops(["export", "DB_PASS=x"], [1])
    }

    func testPrefixAssignmentWithTokenNameDropped() {
        assertDrops(["GITHUB_TOKEN=abc", "make"], [0])
    }

    func testNonSecretAssignmentKept() {
        assertDrops(["export", "EDITOR=vim"], [])
    }

    func testPwdAssignmentDroppedOverSuppressionAccepted() {
        assertDrops(["PWD=/tmp"], [0])
    }

    func testAssignmentNameMustBeIdentifierSoOtherFlagsAreUntouched() {
        assertDrops(["rsync", "--keyfile=a", "x"], [])
    }

    func testTrackerDropsCredentialAfterDroppedBearer() {
        var t = InputTokenTracker()
        let committed = t.observe(Array("curl -H 'Authorization: Bearer abc' https://x ".utf8))
        XCTAssertEqual(committed.map(\.token), ["curl", "-H", "'Authorization:", "https://x"])
        XCTAssertEqual(t.droppedAsSecret, 2)
    }

    func testSchemeLookingWordWithoutHeaderDropsNothing() {
        assertDrops(["vault", "token", "lookup"], [])
        assertDrops(["man", "basic", "usage"], [])
    }

    func testHeaderValueThatIsNotASchemeDropsOnlyThatToken() {
        assertDrops(["curl", "-H", "Authorization:", "abc", "https://x"], [3])
    }

    func testSuggestionAfterSchemeWordIsNotSuppressed() {
        XCTAssertFalse(isSecretValueToken("", precededBy: "basic"))
        XCTAssertFalse(isSecretValueToken("usage", precededBy: "basic"))
        XCTAssertFalse(isSecretValueToken("lookup", precededBy: "token"))
    }

    func testTrackerKeepsWordsAfterSchemeWordWithoutHeader() {
        var t = InputTokenTracker()
        let committed = t.observe(Array("vault token lookup man basic usage ".utf8))
        XCTAssertEqual(committed.map(\.token), ["vault", "token", "lookup", "man", "basic", "usage"])
        XCTAssertEqual(t.droppedAsSecret, 0)
    }
}
