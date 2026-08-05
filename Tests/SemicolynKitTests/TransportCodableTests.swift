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
        XCTAssertEqual(Transport.et.displayName, "Eternal Terminal")
    }

    // Summaries are non-empty and mention the defining tradeoff (observable content check).
    func testSummariesMentionKeyTradeoff() {
        XCTAssertTrue(Transport.ssh.summary.contains("roaming"))
        XCTAssertTrue(Transport.mosh.summary.contains("panes"))
        XCTAssertTrue(Transport.et.summary.contains("etserver"))
    }

    // A Host encoded BEFORE the transport field existed (no "transport" key) must
    // decode with transport == .inherit, not throw keyNotFound.
    func testHostWithoutTransportKeyDecodesAsInherit() throws {
        // Encode a current Host, then strip the transport key to simulate a legacy blob.
        let h = Host(id: UUID(), label: "legacy", hostName: "h.example")
        var dict = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(h)) as! [String: Any]
        dict.removeValue(forKey: "transport")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSONDecoder().decode(Host.self, from: legacyData)
        XCTAssertEqual(back.transport, .inherit)
        XCTAssertEqual(back.hostName, "h.example")
    }

    func testDefaultsWithoutTransportKeyDecodesAsInherit() throws {
        let d = Defaults()
        var dict = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(d)) as! [String: Any]
        dict.removeValue(forKey: "transport")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSONDecoder().decode(Defaults.self, from: legacyData)
        XCTAssertEqual(back.transport, .inherit)
    }

    // A Host with an explicit transport round-trips.
    func testHostTransportRoundTrips() throws {
        var h = Host(id: UUID(), label: "et-host", hostName: "h")
        h.transport = .explicit(.et)
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.transport, .explicit(.et))
    }
}
