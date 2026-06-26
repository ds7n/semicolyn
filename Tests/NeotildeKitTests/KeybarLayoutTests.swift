// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class KeybarLayoutTests: XCTestCase {
    func testDefaultLockedRegionIsEscPadModifierTab() {
        XCTAssertEqual(KeybarLayout.default.locked, [.escPill, .pad, .modifier, .tab])
    }

    func testDefaultScrollSymbolsMatchSpec() {
        XCTAssertEqual(KeybarLayout.default.scroll,
                       [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")")])
    }

    func testEscAndPadAreLockedNotInScroll() {
        XCTAssertFalse(KeybarLayout.default.scroll.contains(.escPill))
        XCTAssertFalse(KeybarLayout.default.scroll.contains(.pad))
    }
}
