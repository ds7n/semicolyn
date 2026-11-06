// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `moshTargetAddress` (security audit L2): Mosh goes to the IP SSH verified, not a
/// second DNS answer.
final class MoshTargetAddressTests: XCTestCase {
    /// A resolver that records whether it was asked, answering a different address.
    private final class Resolver {
        var asked: [String] = []
        func resolve(_ name: String) -> String? { asked.append(name); return "203.0.113.9" }
    }

    // Adversarial: DNS now answers differently; the verified peer IP still wins and
    // DNS is not consulted at all.
    func testPeerIPWinsOverDNS() {
        let r = Resolver()
        XCTAssertEqual(moshTargetAddress(peerIP: "198.51.100.7", hostName: "box.example", resolve: r.resolve),
                       "198.51.100.7")
        XCTAssertEqual(r.asked, [])
    }

    func testIPv6PeerUsed() {
        let r = Resolver()
        XCTAssertEqual(moshTargetAddress(peerIP: "2001:db8::5", hostName: "box.example", resolve: r.resolve),
                       "2001:db8::5")
        XCTAssertEqual(r.asked, [])
    }

    // Through a jump host there is no peer IP: fall back to resolving the name.
    func testNoPeerFallsBackToDNS() {
        let r = Resolver()
        XCTAssertEqual(moshTargetAddress(peerIP: nil, hostName: "box.example", resolve: r.resolve),
                       "203.0.113.9")
        XCTAssertEqual(r.asked, ["box.example"])
    }

    // BVA: an empty peer string is not an address.
    func testEmptyPeerFallsBackToDNS() {
        let r = Resolver()
        XCTAssertEqual(moshTargetAddress(peerIP: "", hostName: "box.example", resolve: r.resolve),
                       "203.0.113.9")
        XCTAssertEqual(r.asked, ["box.example"])
    }

    // A link-local IPv6 peer loses its zone in string form, so it can't be dialled.
    func testLinkLocalPeerFallsBackToDNS() {
        let r = Resolver()
        XCTAssertEqual(moshTargetAddress(peerIP: "FE80::1", hostName: "box.local", resolve: r.resolve),
                       "203.0.113.9")
        XCTAssertEqual(r.asked, ["box.local"])
    }

    // Neither source works: nil (caller falls back to SSH).
    func testUnresolvableReturnsNil() {
        XCTAssertNil(moshTargetAddress(peerIP: nil, hostName: "nope.invalid", resolve: { _ in nil }))
    }
}
