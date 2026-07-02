// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshLaunchDecisionTests: XCTestCase {
    // Enabled + a good handoff → launch Mosh with those params.
    func testEnabledAndSuccessLaunchesMosh() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .success(port: 60001, key: "K"))
        XCTAssertEqual(d, .mosh(port: 60001, key: "K"))
    }

    // Disabled → never Mosh, even if a handoff somehow parsed.
    func testDisabledFallsBack() {
        let d = moshLaunchDecision(enabled: false, bootstrap: .success(port: 60001, key: "K"))
        XCTAssertEqual(d, .fallbackSSH(reason: "Mosh not enabled for this host"))
    }

    // Enabled but no MOSH CONNECT → mosh-server missing/failed → fall back.
    func testEnabledNoConnectLineFallsBack() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .failed(.noConnectLine))
        XCTAssertEqual(d, .fallbackSSH(reason: "mosh-server produced no session (is mosh installed on the host?)"))
    }

    // Enabled but malformed handoff → fall back with a distinct reason.
    func testEnabledMalformedFallsBack() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .failed(.malformed("MOSH CONNECT x")))
        XCTAssertEqual(d, .fallbackSSH(reason: "could not parse mosh-server output"))
    }
}
