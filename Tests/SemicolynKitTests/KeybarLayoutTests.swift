// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarLayoutTests: XCTestCase {
    func testDefaultLeftRegionIsEscModifierTab() {
        XCTAssertEqual(KeybarLayout.default.left, [.escPill, .modifier, .tab])
    }

    func testDefaultMiddleSymbolsMatchSpec() {
        // Fn is an explicit, reorderable/removable middle slot (4d) rather than
        // auto-appended at render time.
        XCTAssertEqual(KeybarLayout.default.middle,
                       [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn])
    }

    func testDefaultRightRegionIsPadAndNothingConstrainedScrolls() {
        XCTAssertEqual(KeybarLayout.default.right, [.pad])
        XCTAssertFalse(KeybarLayout.default.middle.contains(.escPill))
        XCTAssertFalse(KeybarLayout.default.middle.contains(.pad))
    }
}
