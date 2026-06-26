// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// 4d-1 customization core: sticky-rule predicates, layout mutations
/// (remove / move-across-divider / reorder), invariants, Codable persistence,
/// and the reverse-bar direction setting. Spec:
/// `2026-06-15-keybar-customization-design.md` ("Customization model",
/// "Sticky rules summary", "Reverse-bar option").
final class KeybarCustomizationTests: XCTestCase {
    // MARK: - Sticky-rule predicates

    func testOnlyEscAndPadAreNotRemovable() {
        XCTAssertFalse(KeybarLayout.isRemovable(.escPill))
        XCTAssertFalse(KeybarLayout.isRemovable(.pad))
        XCTAssertTrue(KeybarLayout.isRemovable(.modifier))
        XCTAssertTrue(KeybarLayout.isRemovable(.tab))
        XCTAssertTrue(KeybarLayout.isRemovable(.fn))
        XCTAssertTrue(KeybarLayout.isRemovable(.symbol("/")))
    }

    func testOnlyEscAndPadCannotCrossDivider() {
        XCTAssertFalse(KeybarLayout.canMoveAcrossDivider(.escPill))
        XCTAssertFalse(KeybarLayout.canMoveAcrossDivider(.pad))
        XCTAssertTrue(KeybarLayout.canMoveAcrossDivider(.modifier))
        XCTAssertTrue(KeybarLayout.canMoveAcrossDivider(.tab))
        XCTAssertTrue(KeybarLayout.canMoveAcrossDivider(.fn))
        XCTAssertTrue(KeybarLayout.canMoveAcrossDivider(.symbol("~")))
    }

    // MARK: - Remove

    func testRemovingRemovableSlotDropsItFromScroll() {
        let result = KeybarLayout.default.removing(.tab)
        XCTAssertEqual(result?.locked, [.escPill, .pad, .modifier])
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.scroll.contains(.tab))
    }

    func testRemovingSymbolDropsOnlyThatSymbol() {
        let result = KeybarLayout.default.removing(.symbol("~"))
        XCTAssertEqual(result?.scroll,
                       [.symbol("/"), .symbol("|"), .symbol("-"), .symbol("("), .symbol(")"), .fn])
    }

    func testRemovingEscPillIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.removing(.escPill))
    }

    func testRemovingPadIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.removing(.pad))
    }

    // MARK: - Move across divider

    func testMovingModifierToScrollAppendsItToScrollAndDropsFromLocked() {
        let result = KeybarLayout.default.moving(.modifier, toScroll: true)
        XCTAssertEqual(result?.locked, [.escPill, .pad, .tab])
        XCTAssertEqual(result?.scroll.last, .modifier)
    }

    func testMovingScrollSlotBackToLockedAppendsItToLocked() {
        let moved = KeybarLayout.default.moving(.modifier, toScroll: true)!
        let back = moved.moving(.modifier, toScroll: false)
        XCTAssertEqual(back?.locked, [.escPill, .pad, .tab, .modifier])
        XCTAssertFalse(back!.scroll.contains(.modifier))
    }

    func testMovingEscPillAcrossDividerIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.moving(.escPill, toScroll: true))
    }

    func testMovingPadAcrossDividerIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.moving(.pad, toScroll: true))
    }

    // MARK: - Reorder (within a region)

    func testReorderingLockedMovesSlotToNewIndex() {
        // Move Modifier (index 2) to the front (offset 0).
        let result = KeybarLayout.default.reorderingLocked(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(result.locked, [.modifier, .escPill, .pad, .tab])
        XCTAssertEqual(result.scroll, KeybarLayout.default.scroll, "reorder leaves the other region untouched")
    }

    func testReorderingScrollMovesSlotToNewIndex() {
        // Move "/" (index 0) to the end (offset 7, past the last element).
        let result = KeybarLayout.default.reorderingScroll(fromOffsets: IndexSet(integer: 0), toOffset: 7)
        XCTAssertEqual(result.scroll,
                       [.symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn, .symbol("/")])
    }

    // MARK: - Invariants

    func testDefaultLayoutIsValid() {
        XCTAssertTrue(KeybarLayout.default.isValid)
    }

    func testLayoutMissingEscPillIsInvalid() {
        let bad = KeybarLayout(locked: [.pad, .modifier, .tab], scroll: [.fn])
        XCTAssertFalse(bad.isValid)
    }

    func testLayoutWithDuplicateSlotIsInvalid() {
        let bad = KeybarLayout(locked: [.escPill, .pad, .tab], scroll: [.tab, .fn])
        XCTAssertFalse(bad.isValid)
    }

    func testLayoutWithEscPillInScrollIsInvalid() {
        let bad = KeybarLayout(locked: [.pad, .modifier], scroll: [.escPill, .tab, .fn])
        XCTAssertFalse(bad.isValid)
    }

    // MARK: - Codable

    func testLayoutCodableRoundTripPreservesDefault() throws {
        let data = try JSONEncoder().encode(KeybarLayout.default)
        let decoded = try JSONDecoder().decode(KeybarLayout.self, from: data)
        XCTAssertEqual(decoded, KeybarLayout.default)
    }

    func testCustomizedLayoutCodableRoundTrip() throws {
        let custom = KeybarLayout.default.removing(.tab)!.moving(.modifier, toScroll: true)!
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(KeybarLayout.self, from: data)
        XCTAssertEqual(decoded, custom)
    }

    func testSlotDecodesFromStableJSONSchema() throws {
        let fn = try JSONDecoder().decode(KeybarSlot.self, from: Data(#"{"kind":"fn"}"#.utf8))
        XCTAssertEqual(fn, .fn)
        let sym = try JSONDecoder().decode(KeybarSlot.self, from: Data(#"{"kind":"symbol","value":"~"}"#.utf8))
        XCTAssertEqual(sym, .symbol("~"))
    }

    // MARK: - Settings + reverse-bar

    func testDefaultDirectionIsLockedLeft() {
        XCTAssertEqual(KeybarSettings.default.direction, .lockedLeft)
        XCTAssertEqual(KeybarSettings.default.layout, .default)
    }

    func testSettingsCodableRoundTripBothDirections() throws {
        for dir in [KeybarLayoutDirection.lockedLeft, .lockedRight] {
            let settings = KeybarSettings(layout: .default, direction: dir)
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(KeybarSettings.self, from: data)
            XCTAssertEqual(decoded, settings)
            XCTAssertEqual(decoded.direction, dir)
        }
    }
}
