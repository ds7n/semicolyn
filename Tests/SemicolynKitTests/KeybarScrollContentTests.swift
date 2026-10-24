// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarScrollContentTests: XCTestCase {
    // 4d: the scroll region resolves a user-ordered list of slots (symbols, Fn,
    // and slots the user moved down from the locked region).
    private let slots: [KeybarSlot] = [.symbol("/"), .symbol("|"), .symbol("~"), .fn]

    func testNotEngagedShowsUserSlotsInOrder() {
        let items = keybarScrollItems(scrollSlots: slots, fnEngaged: false)
        XCTAssertEqual(items, [.slot(.symbol("/")), .slot(.symbol("|")), .slot(.symbol("~")), .slot(.fn)])
    }

    func testNotEngagedEmptySlotsIsEmpty() {
        XCTAssertEqual(keybarScrollItems(scrollSlots: [], fnEngaged: false), [])
    }

    func testUserMovedModifierRendersAsASlotItem() {
        // A Modifier the user dragged into the scroll region renders inline.
        let items = keybarScrollItems(scrollSlots: [.modifier, .symbol("/")], fnEngaged: false)
        XCTAssertEqual(items, [.slot(.modifier), .slot(.symbol("/"))])
    }

    func testEngagedShowsF1ThroughF12ThenFnAndHidesSymbols() {
        let items = keybarScrollItems(scrollSlots: slots, fnEngaged: true)
        XCTAssertEqual(items, (1...12).map { KeybarScrollItem.fkey($0) } + [.slot(.fn)])
        XCTAssertFalse(items.contains(.slot(.symbol("/"))))
    }
}
