// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    // .wheel: every app -> wheel (app-agnostic universal scroll).
    func testWheelModeIsWheel() {
        let d = altScrollDecision(mode: .wheel)
        XCTAssertEqual(d, AltScrollDecision(keys: .wheel, mode: .wheel, reason: "wheel"))
    }

    // .pageKeysArrows: arrows. NEGATIVE: never wheel.
    func testFallbackModeIsArrows() {
        let d = altScrollDecision(mode: .pageKeysArrows)
        XCTAssertEqual(d, AltScrollDecision(keys: .arrows, mode: .pageKeysArrows, reason: "fallback"))
    }

    // logLine self-contained.
    func testLogLines() {
        XCTAssertEqual(altScrollDecision(mode: .wheel).logLine,
                       "mode=wheel → keys=wheel reason=wheel")
        XCTAssertEqual(altScrollDecision(mode: .pageKeysArrows).logLine,
                       "mode=pageKeysArrows → keys=arrows reason=fallback")
    }
}
