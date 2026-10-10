// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Three-region keybar model: sticky rules, region mutations, invariants,
/// Codable (v2 keys + v1 migration). Spec:
/// `2026-08-14-keybar-keyboard-redesign-design.md` Phase 2 (revised 2026-10-10).
final class KeybarCustomizationTests: XCTestCase {
    private let defaultMiddle: [KeybarSlot] =
        [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn]

    // MARK: - Default

    func testDefaultLayoutHasEscModTabLeftSymbolsMiddlePadRight() {
        XCTAssertEqual(KeybarLayout.default.left, [.escPill, .modifier, .tab])
        XCTAssertEqual(KeybarLayout.default.middle, defaultMiddle)
        XCTAssertEqual(KeybarLayout.default.right, [.pad])
        XCTAssertTrue(KeybarLayout.default.isValid)
    }

    // MARK: - Sticky-rule predicates

    func testOnlyEscAndPadAreNotRemovable() {
        XCTAssertFalse(KeybarLayout.isRemovable(.escPill))
        XCTAssertFalse(KeybarLayout.isRemovable(.pad))
        XCTAssertTrue(KeybarLayout.isRemovable(.modifier))
        XCTAssertTrue(KeybarLayout.isRemovable(.tab))
        XCTAssertTrue(KeybarLayout.isRemovable(.fn))
        XCTAssertTrue(KeybarLayout.isRemovable(.symbol("/")))
    }

    func testEscAndPadAreAllowedOnlyInLockedRegions() {
        XCTAssertEqual(KeybarLayout.allowedRegions(for: .escPill), [.left, .right])
        XCTAssertEqual(KeybarLayout.allowedRegions(for: .pad), [.left, .right])
        XCTAssertTrue(KeybarLayout.isLockedOnly(.escPill))
        XCTAssertTrue(KeybarLayout.isLockedOnly(.pad))
    }

    func testOrdinarySlotsAreAllowedInAllRegions() {
        for slot in [KeybarSlot.modifier, .tab, .fn, .symbol("~")] {
            XCTAssertEqual(KeybarLayout.allowedRegions(for: slot), [.left, .middle, .right], "\(slot)")
            XCTAssertFalse(KeybarLayout.isLockedOnly(slot), "\(slot)")
        }
    }

    // MARK: - Lookup

    func testRegionOfFindsEachRegionAndNilWhenAbsent() {
        XCTAssertEqual(KeybarLayout.default.region(of: .escPill), .left)
        XCTAssertEqual(KeybarLayout.default.region(of: .fn), .middle)
        XCTAssertEqual(KeybarLayout.default.region(of: .pad), .right)
        XCTAssertNil(KeybarLayout.default.region(of: .symbol("#")))
    }

    func testSlotsInRegionReturnsThatRegion() {
        XCTAssertEqual(KeybarLayout.default.slots(in: .left), [.escPill, .modifier, .tab])
        XCTAssertEqual(KeybarLayout.default.slots(in: .middle), defaultMiddle)
        XCTAssertEqual(KeybarLayout.default.slots(in: .right), [.pad])
        XCTAssertEqual(KeybarLayout.default.allSlots, [.escPill, .modifier, .tab] + defaultMiddle + [.pad])
    }

    // MARK: - Remove

    func testRemovingLeftSlotDropsOnlyIt() {
        let result = KeybarLayout.default.removing(.tab)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .modifier], middle: defaultMiddle, right: [.pad]))
    }

    func testRemovingMiddleSymbolDropsOnlyThatSymbol() {
        let result = KeybarLayout.default.removing(.symbol("~"))
        XCTAssertEqual(result?.middle,
                       [.symbol("/"), .symbol("|"), .symbol("-"), .symbol("("), .symbol(")"), .fn])
        XCTAssertEqual(result?.left, KeybarLayout.default.left)
        XCTAssertEqual(result?.right, KeybarLayout.default.right)
    }

    func testRemovingEscPillIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.removing(.escPill))
    }

    func testRemovingPadIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.removing(.pad))
    }

    // MARK: - Move between regions

    func testMovingModifierToMiddleAppendsItThere() {
        let result = KeybarLayout.default.moving(.modifier, to: .middle)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .tab], middle: defaultMiddle + [.modifier], right: [.pad]))
    }

    func testMovingModifierToRightAppendsAfterPad() {
        let result = KeybarLayout.default.moving(.modifier, to: .right)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .tab], middle: defaultMiddle, right: [.pad, .modifier]))
    }

    func testMovingMiddleSlotToLeftAppendsToLeft() {
        let result = KeybarLayout.default.moving(.fn, to: .left)
        XCTAssertEqual(result?.left, [.escPill, .modifier, .tab, .fn])
        XCTAssertEqual(result?.middle, Array(defaultMiddle.dropLast()))
    }

    func testMovingPadToLeftIsAllowed() {
        let result = KeybarLayout.default.moving(.pad, to: .left)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .modifier, .tab, .pad], middle: defaultMiddle, right: []))
    }

    func testMovingEscToRightIsAllowed() {
        let result = KeybarLayout.default.moving(.escPill, to: .right)
        XCTAssertEqual(result, KeybarLayout(left: [.modifier, .tab], middle: defaultMiddle, right: [.pad, .escPill]))
    }

    func testMovingEscToMiddleIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.moving(.escPill, to: .middle))
    }

    func testMovingPadToMiddleIsRefusedWithNil() {
        XCTAssertNil(KeybarLayout.default.moving(.pad, to: .middle))
    }

    func testMovingToCurrentRegionLeavesOrderUnchanged() {
        // Review Focus 3: must not reshuffle Esc to the end of left.
        XCTAssertEqual(KeybarLayout.default.moving(.escPill, to: .left), KeybarLayout.default)
    }

    // MARK: - Append / filter

    func testAppendingNewSlotAddsToEndOfRegion() {
        let result = KeybarLayout.default.appending(.symbol("#"), to: .middle)
        XCTAssertEqual(result.middle, defaultMiddle + [.symbol("#")])
    }

    func testAppendingSlotAlreadyOnBarIsNoOp() {
        // Review Focus 4: re-adding must not duplicate.
        XCTAssertEqual(KeybarLayout.default.appending(.tab, to: .middle), KeybarLayout.default)
    }

    func testFilteringRemovesMatchesFromEveryRegion() {
        let layout = KeybarLayout(left: [.escPill, .fn], middle: [.symbol("/")], right: [.pad, .tab])
        let result = layout.filtering { $0 != .fn && $0 != .tab }
        XCTAssertEqual(result, KeybarLayout(left: [.escPill], middle: [.symbol("/")], right: [.pad]))
    }

    // MARK: - Reorder (within a region)

    func testReorderingLeftMovesSlotToNewIndex() {
        // Move Tab (index 2) to the front (offset 0).
        let result = KeybarLayout.default.reordering(.left, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(result.left, [.tab, .escPill, .modifier])
        XCTAssertEqual(result.middle, defaultMiddle, "reorder leaves other regions untouched")
        XCTAssertEqual(result.right, [.pad])
    }

    func testReorderingMiddleMovesSlotToEnd() {
        // Move "/" (index 0) past the last element (offset 7).
        let result = KeybarLayout.default.reordering(.middle, fromOffsets: IndexSet(integer: 0), toOffset: 7)
        XCTAssertEqual(result.middle,
                       [.symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn, .symbol("/")])
    }

    func testReorderingRightPermutesRight() {
        let layout = KeybarLayout(left: [.escPill], middle: [], right: [.pad, .tab])
        let result = layout.reordering(.right, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(result.right, [.tab, .pad])
    }

    // MARK: - Invariants

    func testLayoutMissingEscPillIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.modifier], middle: [.fn], right: [.pad]).isValid)
    }

    func testLayoutWithTwoEscPillsIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.escPill], middle: [], right: [.pad, .escPill]).isValid)
    }

    func testLayoutMissingPadIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.escPill], middle: [.fn], right: []).isValid)
    }

    func testLayoutWithEscPillInMiddleIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.modifier], middle: [.escPill], right: [.pad]).isValid)
    }

    func testLayoutWithPadInMiddleIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.escPill], middle: [.pad], right: []).isValid)
    }

    func testLayoutWithEscAndPadBothRightIsValid() {
        XCTAssertTrue(KeybarLayout(left: [], middle: [.fn], right: [.pad, .escPill]).isValid)
    }

    func testLayoutWithDuplicateAcrossRegionsIsInvalid() {
        XCTAssertFalse(KeybarLayout(left: [.escPill, .tab], middle: [.tab], right: [.pad]).isValid)
    }

    // MARK: - v1 migration (pure)

    func testFromV1NonMirroredMovesPadRightKeepsOrder() {
        let result = KeybarLayout.fromV1(locked: [.escPill, .pad, .modifier, .tab],
                                         scroll: defaultMiddle, mirrored: false)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .modifier, .tab], middle: defaultMiddle, right: [.pad]))
    }

    func testFromV1NonMirroredWithoutPadLeavesRightEmpty() {
        let result = KeybarLayout.fromV1(locked: [.escPill, .tab], scroll: [.fn], mirrored: false)
        XCTAssertEqual(result, KeybarLayout(left: [.escPill, .tab], middle: [.fn], right: []))
    }

    func testFromV1MirroredPutsReversedLockedRight() {
        let result = KeybarLayout.fromV1(locked: [.escPill, .pad, .modifier, .tab],
                                         scroll: [.fn], mirrored: true)
        XCTAssertEqual(result, KeybarLayout(left: [], middle: [.fn], right: [.tab, .modifier, .pad, .escPill]))
    }

    // MARK: - Codable

    func testLayoutCodableRoundTripPreservesDefault() throws {
        let data = try JSONEncoder().encode(KeybarLayout.default)
        XCTAssertEqual(try JSONDecoder().decode(KeybarLayout.self, from: data), KeybarLayout.default)
    }

    func testCustomizedLayoutCodableRoundTrip() throws {
        let custom = KeybarLayout.default.removing(.tab)!.moving(.modifier, to: .right)!
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(KeybarLayout.self, from: data), custom)
    }

    func testEncodedLayoutUsesV2KeysOnly() throws {
        let data = try JSONEncoder().encode(KeybarLayout.default)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["left", "middle", "right"])
    }

    func testV1LayoutJSONDecodesAsNonMirroredMigration() throws {
        let json = Data("""
        {"locked":[{"kind":"escPill"},{"kind":"pad"},{"kind":"tab"}],
         "scroll":[{"kind":"symbol","value":"/"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(KeybarLayout.self, from: json)
        XCTAssertEqual(decoded, KeybarLayout(left: [.escPill, .tab], middle: [.symbol("/")], right: [.pad]))
    }

    func testLayoutJSONWithNeitherSchemaFailsWithKeyNotFound() {
        let json = Data(#"{"other":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybarLayout.self, from: json)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
        }
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
