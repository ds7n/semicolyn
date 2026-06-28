// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarScrollContentTests: XCTestCase {
    private let p = PromotionSlot(tap: ":", up: ";", down: nil)
    // 4d: the scroll region resolves a user-ordered list of slots (symbols, Fn,
    // and slots the user moved down from the locked region) plus runtime promotions.
    private let slots: [KeybarSlot] = [.symbol("/"), .symbol("|"), .symbol("~"), .fn]

    func testNotEngagedShowsPromotionsThenUserSlots() {
        let items = keybarScrollItems(promotions: [p], scrollSlots: slots, fnEngaged: false)
        XCTAssertEqual(items, [.promotion(p), .slot(.symbol("/")), .slot(.symbol("|")),
                               .slot(.symbol("~")), .slot(.fn)])
    }

    func testNoPromotionsShowsUserSlotsOnly() {
        let items = keybarScrollItems(promotions: [], scrollSlots: slots, fnEngaged: false)
        XCTAssertEqual(items, [.slot(.symbol("/")), .slot(.symbol("|")), .slot(.symbol("~")), .slot(.fn)])
    }

    func testUserMovedModifierRendersAsASlotItem() {
        // A Modifier the user dragged into the scroll region renders inline.
        let items = keybarScrollItems(promotions: [], scrollSlots: [.modifier, .symbol("/")], fnEngaged: false)
        XCTAssertEqual(items, [.slot(.modifier), .slot(.symbol("/"))])
    }

    func testEngagedShowsF1ThroughF12ThenFnAndHidesPromotionsAndSymbols() {
        let items = keybarScrollItems(promotions: [p], scrollSlots: slots, fnEngaged: true)
        XCTAssertEqual(items, (1...12).map { KeybarScrollItem.fkey($0) } + [.slot(.fn)])
        XCTAssertFalse(items.contains(.promotion(p)))
        XCTAssertFalse(items.contains(.slot(.symbol("/"))))
    }
}
