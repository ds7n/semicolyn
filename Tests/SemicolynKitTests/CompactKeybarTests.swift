// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Phase 4e compact keybar: when a hardware keyboard is connected the bar shrinks
/// to the built-in widgets (Esc pill · Pad · Modifier · Tab), honoring each
/// fixed region's order and side, plus the "hide keybar with hardware keyboard" setting
/// (external-keyboard spec "Keybar behavior").
final class CompactKeybarTests: XCTestCase {
    // MARK: - compactKeybarSlots

    func testDefaultLayoutSplitsBuiltinsBySide() {
        let result = compactKeybarSlots(left: KeybarLayout.default.left, right: KeybarLayout.default.right)
        XCTAssertEqual(result.left, [.escPill, .modifier, .tab])
        XCTAssertEqual(result.right, [.pad])
    }

    func testPreservesUserOrderWithinEachSide() {
        let result = compactKeybarSlots(left: [.tab, .escPill], right: [.modifier, .pad])
        XCTAssertEqual(result.left, [.tab, .escPill])
        XCTAssertEqual(result.right, [.modifier, .pad])
    }

    func testDropsRemovedBuiltins() {
        let result = compactKeybarSlots(left: [.escPill], right: [.pad])
        XCTAssertEqual(result.left, [.escPill])
        XCTAssertEqual(result.right, [.pad])
    }

    func testExcludesNonBuiltinSlotsOnBothSides() {
        let result = compactKeybarSlots(left: [.escPill, .symbol("/")], right: [.fn, .pad])
        XCTAssertEqual(result.left, [.escPill])
        XCTAssertEqual(result.right, [.pad])
    }

    // MARK: - hideKeybarWithHardwareKeyboard setting

    func testDefaultShowsKeybar() {
        XCTAssertFalse(KeybarSettings.default.hideKeybarWithHardwareKeyboard)
    }

    func testSettingRoundTrips() throws {
        var settings = KeybarSettings.default
        settings.hideKeybarWithHardwareKeyboard = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(KeybarSettings.self, from: data)
        XCTAssertTrue(decoded.hideKeybarWithHardwareKeyboard)
    }

    func testPreExistingBlobDefaultsToShown() throws {
        // A blob written before 4e has no key → keybar stays shown (false).
        let oldBlob = Data("""
        {"layout":{"locked":[{"kind":"escPill"},{"kind":"pad"}],"scroll":[]},
         "direction":"lockedLeft"}
        """.utf8)
        let decoded = try JSONDecoder().decode(KeybarSettings.self, from: oldBlob)
        XCTAssertFalse(decoded.hideKeybarWithHardwareKeyboard)
    }
}
