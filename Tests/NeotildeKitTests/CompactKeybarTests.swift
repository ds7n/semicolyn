// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// Phase 4e compact keybar: when a hardware keyboard is connected the bar shrinks
/// to the built-in widgets (Esc pill · Pad · Modifier · Tab), honoring the user's
/// locked-region order, plus the "hide keybar with hardware keyboard" setting
/// (external-keyboard spec "Keybar behavior").
final class CompactKeybarTests: XCTestCase {
    // MARK: - compactKeybarSlots

    func testDefaultLockedYieldsAllFourBuiltins() {
        XCTAssertEqual(compactKeybarSlots(locked: KeybarLayout.default.locked),
                       [.escPill, .pad, .modifier, .tab])
    }

    func testPreservesUserLockedOrder() {
        XCTAssertEqual(compactKeybarSlots(locked: [.tab, .modifier, .escPill, .pad]),
                       [.tab, .modifier, .escPill, .pad])
    }

    func testDropsRemovedBuiltins() {
        // User removed Modifier and Tab; compact bar shows only what's present.
        XCTAssertEqual(compactKeybarSlots(locked: [.escPill, .pad]),
                       [.escPill, .pad])
    }

    func testExcludesNonBuiltinSlotsThatStrayedIntoLocked() {
        XCTAssertEqual(compactKeybarSlots(locked: [.escPill, .pad, .symbol("/"), .fn]),
                       [.escPill, .pad])
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
