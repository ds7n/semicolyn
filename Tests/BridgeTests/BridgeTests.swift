// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynSSHCoreFFI

final class BridgeTests: XCTestCase {
    func testCoreVersionRoundTripsFromRust() {
        // The Rust crate version is the single source of truth; the bridge
        // must surface it verbatim to Swift, proving Rust→UniFFI→Swift works.
        XCTAssertEqual(coreVersion(), "0.1.0")
    }
}
