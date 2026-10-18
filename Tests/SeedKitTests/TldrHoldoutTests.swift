// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

final class TldrHoldoutTests: XCTestCase {
    func testHoldoutIsStableAndAboutTenPercent() {
        XCTAssertEqual(TldrHoldout.isHeldOut(pageStem: "git"), TldrHoldout.isHeldOut(pageStem: "git"))
        let stems = (0..<2000).map { "tool\($0)" }
        let held = stems.filter { TldrHoldout.isHeldOut(pageStem: $0) }.count
        XCTAssertTrue((150...250).contains(held), "held=\(held)")
    }

    /// FNV-1a 64 values computed independently (hash % 10): git=5, ls=8, tar=8, npm=0.
    func testKnownStems() {
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "git"))
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "ls"))
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "tar"))
        XCTAssertTrue(TldrHoldout.isHeldOut(pageStem: "npm"))
    }
}
