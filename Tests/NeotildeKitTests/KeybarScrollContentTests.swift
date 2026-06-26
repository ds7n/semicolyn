// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class KeybarScrollContentTests: XCTestCase {
    private let p = PromotionSlot(tap: ":", up: ";", down: nil)
    private let syms = ["/", "|", "~"]

    func testNotEngagedShowsPromotionsThenSymbolsThenFn() {
        let items = keybarScrollItems(promotions: [p], defaultSymbols: syms, fnEngaged: false)
        XCTAssertEqual(items, [.promotion(p), .symbol("/"), .symbol("|"), .symbol("~"), .fn])
    }

    func testNoPromotionsShowsSymbolsThenFn() {
        let items = keybarScrollItems(promotions: [], defaultSymbols: syms, fnEngaged: false)
        XCTAssertEqual(items, [.symbol("/"), .symbol("|"), .symbol("~"), .fn])
    }

    func testEngagedShowsF1ThroughF12ThenFnAndHidesPromotionsAndSymbols() {
        let items = keybarScrollItems(promotions: [p], defaultSymbols: syms, fnEngaged: true)
        XCTAssertEqual(items, (1...12).map { KeybarScrollItem.fkey($0) } + [.fn])
        XCTAssertFalse(items.contains(.promotion(p)))
        XCTAssertFalse(items.contains(.symbol("/")))
    }
}
