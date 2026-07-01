// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ANSIPaletteTests: XCTestCase {
    /// Build a 16-color palette where each color encodes its own index in the blue channel.
    private func indexPalette() -> ANSIPalette {
        ANSIPalette((0..<16).map { ThemeColor(String(format: "#0000%02X", $0)) })
    }

    func testSlotRawValuesAreSwiftTermIndexOrder() {
        // installColors relies on rawValue == ANSI index.
        XCTAssertEqual(ANSISlot.black.rawValue, 0)
        XCTAssertEqual(ANSISlot.red.rawValue, 1)
        XCTAssertEqual(ANSISlot.green.rawValue, 2)
        XCTAssertEqual(ANSISlot.yellow.rawValue, 3)
        XCTAssertEqual(ANSISlot.blue.rawValue, 4)
        XCTAssertEqual(ANSISlot.magenta.rawValue, 5)
        XCTAssertEqual(ANSISlot.cyan.rawValue, 6)
        XCTAssertEqual(ANSISlot.white.rawValue, 7)
        XCTAssertEqual(ANSISlot.brightBlue.rawValue, 12)
        XCTAssertEqual(ANSISlot.brightWhite.rawValue, 15)
        XCTAssertEqual(ANSISlot.allCases.count, 16)
    }

    func testSubscriptResolvesSlotToAuthoredColor() {
        let p = indexPalette()
        XCTAssertEqual(p[.blue], ThemeColor("#000004"))
        XCTAssertEqual(p[.brightBlue], ThemeColor("#00000C"))
    }

    func testOrderedReturnsSixteenInIndexOrder() {
        let p = indexPalette()
        let ordered = p.ordered()
        XCTAssertEqual(ordered.count, 16)
        XCTAssertEqual(ordered[0], ThemeColor("#000000"))
        XCTAssertEqual(ordered[15], ThemeColor("#00000F"))
        // ordered[i] must equal the slot with rawValue i.
        for slot in ANSISlot.allCases {
            XCTAssertEqual(ordered[slot.rawValue], p[slot])
        }
    }
}
