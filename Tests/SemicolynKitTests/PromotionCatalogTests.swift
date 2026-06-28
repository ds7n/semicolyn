// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PromotionCatalogTests: XCTestCase {
    func testNilOverrideReturnsBundledNoWarning() {
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: nil)
        XCTAssertEqual(reg, PromotionRegistry.bundledDefault)
        XCTAssertNil(warning)
    }

    func testValidJSONOverrideDecodesAndMerges() throws {
        // Includes a backslash promotion to prove JSON escaping round-trips.
        let json = Data("""
        { "vim": { "promote": [ {"tap": "Z"} ] },
          "awk": { "promote": [ {"tap": "\\\\", "up": "|"} ] } }
        """.utf8)
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: json)
        XCTAssertNil(warning)
        XCTAssertEqual(reg.set(for: "vim")?.promote.map(\.tap), ["Z"])   // user wins
        XCTAssertEqual(reg.set(for: "awk")?.promote.first, PromotionSlot(tap: "\\", up: "|", down: nil))
        XCTAssertNotNil(reg.set(for: "psql"))   // untouched bundled entry survives
    }

    func testMalformedJSONFallsBackToBundledWithWarning() {
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: Data("{ not json".utf8))
        XCTAssertEqual(reg, PromotionRegistry.bundledDefault)   // never crash; full fallback
        XCTAssertEqual(warning, "Keybar promotion override file is invalid — using defaults.")
    }
}
