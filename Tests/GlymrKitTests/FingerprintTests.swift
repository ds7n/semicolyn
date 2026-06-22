// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class FingerprintTests: XCTestCase {
    func testTruncationMatchesSpecFormat() {
        let fp = Fingerprint("SHA256:s4xLm2abcdefghijklWYzZ")
        XCTAssertEqual(fp.full, "SHA256:s4xLm2abcdefghijklWYzZ")
        XCTAssertEqual(fp.truncated, "SHA256:s4xLm…WYzZ")   // first 5 of body + … + last 4
    }

    func testShortFingerprintIsNotTruncated() {
        // body "abc" (3 chars) ≤ 9 → returned whole, no ellipsis.
        let fp = Fingerprint("SHA256:abc")
        XCTAssertEqual(fp.truncated, "SHA256:abc")
        XCTAssertFalse(fp.truncated.contains("…"))
    }

    func testBoundaryBodyOfNineIsNotTruncatedTenIs() {
        XCTAssertEqual(Fingerprint("SHA256:123456789").truncated, "SHA256:123456789")     // 9 → whole
        XCTAssertEqual(Fingerprint("SHA256:1234567890").truncated, "SHA256:12345…7890")   // 10 → truncated
    }
}
