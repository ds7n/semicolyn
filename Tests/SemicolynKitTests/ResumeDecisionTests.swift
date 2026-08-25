// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ResumeDecisionTests: XCTestCase {
    private func rec(_ t: Transport) -> ResumableSession {
        ResumableSession(sessionID: UUID(), hostID: UUID(), transport: t, host: "h", port: 1,
                         tmuxSessionName: nil, lastConnectedAt: Date(timeIntervalSince1970: 0))
    }

    func testNoRecordIsNone() {
        XCTAssertEqual(resumeDecision(record: nil, isWarm: true, secretPresent: true), .none)
        XCTAssertEqual(resumeDecision(record: nil, isWarm: false, secretPresent: false), .none)
    }

    func testRawAlwaysPrompts() {
        let r = rec(.ssh)
        XCTAssertEqual(resumeDecision(record: r, isWarm: true, secretPresent: false), .promptRaw(r))
        XCTAssertEqual(resumeDecision(record: r, isWarm: false, secretPresent: false), .promptRaw(r))
    }

    func testMoshEtWarmReforegrounds() {
        for t in [Transport.mosh, .et] {
            XCTAssertEqual(resumeDecision(record: rec(t), isWarm: true, secretPresent: true), .reforeground)
            // warm does not need the secret (live transport self-reconnects):
            XCTAssertEqual(resumeDecision(record: rec(t), isWarm: true, secretPresent: false), .reforeground)
        }
    }

    func testMoshEtColdWithSecretReattaches() {
        for t in [Transport.mosh, .et] {
            let r = rec(t)
            XCTAssertEqual(resumeDecision(record: r, isWarm: false, secretPresent: true), .coldReattach(r))
        }
    }

    func testMoshEtColdWithoutSecretIsNone() {
        for t in [Transport.mosh, .et] {
            XCTAssertEqual(resumeDecision(record: rec(t), isWarm: false, secretPresent: false), .none)
        }
    }
}
