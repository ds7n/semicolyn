// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportCodableTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(Transport.ssh.rawValue, "ssh")
        XCTAssertEqual(Transport.mosh.rawValue, "mosh")
        XCTAssertEqual(Transport.et.rawValue, "et")
    }

    func testAllCases() {
        XCTAssertEqual(Transport.allCases, [.ssh, .mosh, .et])
    }

    func testRoundTrips() throws {
        for t in Transport.allCases {
            let data = try JSONEncoder().encode(t)
            XCTAssertEqual(try JSONDecoder().decode(Transport.self, from: data), t)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(Transport.ssh.displayName, "SSH")
        XCTAssertEqual(Transport.mosh.displayName, "Mosh")
        XCTAssertEqual(Transport.et.displayName, "ET")
    }

    // Summaries are non-empty and mention the defining tradeoff (observable content check).
    func testSummariesMentionKeyTradeoff() {
        XCTAssertTrue(Transport.ssh.summary.contains("roaming"))
        XCTAssertTrue(Transport.mosh.summary.contains("panes"))
        XCTAssertTrue(Transport.et.summary.contains("etserver"))
    }
}
