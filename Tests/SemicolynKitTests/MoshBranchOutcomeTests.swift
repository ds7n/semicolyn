// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshBranchOutcomeTests: XCTestCase {
    // Valid: enabled + clean handoff → mosh with exact port/key.
    func testEnabledValidHandoffIsMosh() {
        let out = "MOSH CONNECT 60001 x5HdELy8n2XkX9pO4dO2Zw"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: true),
                       .mosh(port: 60001, key: "x5HdELy8n2XkX9pO4dO2Zw"))
    }

    // Valid: handoff amid banner chatter still parses.
    func testHandoffAmidChatterIsMosh() {
        let out = "Last login: Tue\nMOSH CONNECT 60002 KEYKEYKEYKEY\nbye"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: true),
                       .mosh(port: 60002, key: "KEYKEYKEYKEY"))
    }

    // Invalid: disabled → fallback with the disabled reason even if a line parsed.
    func testDisabledIsFallbackDisabledReason() {
        let out = "MOSH CONNECT 60001 KEYKEYKEYKEY"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: false),
                       .fallback(reason: "Mosh not enabled for this host — using SSH"))
    }

    // Invalid: no MOSH CONNECT line → mosh-server-not-found fallback.
    func testNoConnectLineIsNotFoundFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "mosh-server: command not found", enabled: true),
                       .fallback(reason: "mosh-server not found on host — using SSH"))
    }

    // Boundary: empty stdout (bootstrap timeout is passed as "") → not-found fallback.
    func testEmptyStdoutIsNotFoundFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "", enabled: true),
                       .fallback(reason: "mosh-server not found on host — using SSH"))
    }

    // Invalid: malformed line (non-numeric port) → parse-failure fallback.
    func testMalformedLineIsParseFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "MOSH CONNECT abc KEY", enabled: true),
                       .fallback(reason: "couldn't parse mosh-server output — using SSH"))
    }
}
