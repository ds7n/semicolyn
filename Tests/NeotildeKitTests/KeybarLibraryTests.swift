// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// 4d-2 library plumbing: the new `KeybarSlot` cases (`.custom` / `.pinnedMacro`),
/// the `KeybarLibrary` registry, and folding the library into `KeybarSettings`
/// with back-compatible decoding of pre-4d-2 persisted blobs.
final class KeybarLibraryTests: XCTestCase {
    private let mDeploy = Macro(id: MacroID("m-deploy"), name: "Deploy",
                                body: [MacroEvent(key: .char("d")), MacroEvent(key: .enter)])
    private let slotKc = CustomSlot(id: CustomSlotID("s-kc"), label: "kc",
                                    tap: GestureBinding(macro: MacroID("m-deploy")))

    // MARK: - New KeybarSlot cases

    func testCustomAndPinnedMacroSlotsRoundTrip() throws {
        for slot in [KeybarSlot.custom(CustomSlotID("s1")), .pinnedMacro(MacroID("m1"))] {
            let data = try JSONEncoder().encode(slot)
            XCTAssertEqual(try JSONDecoder().decode(KeybarSlot.self, from: data), slot)
        }
    }

    func testNewSlotsAreRemovableAndMovable() {
        for slot in [KeybarSlot.custom(CustomSlotID("s1")), .pinnedMacro(MacroID("m1"))] {
            XCTAssertTrue(KeybarLayout.isRemovable(slot))
            XCTAssertTrue(KeybarLayout.canMoveAcrossDivider(slot))
        }
    }

    func testExistingSlotJSONStillDecodes() throws {
        // Forward-safe schema: a pre-4d-2 symbol slot decodes unchanged.
        let json = Data(#"{"kind":"symbol","value":"/"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KeybarSlot.self, from: json), .symbol("/"))
    }

    func testLayoutWithCustomAndMacroSlotsIsValidAndRoundTrips() throws {
        let layout = KeybarLayout(
            locked: [.escPill, .pad],
            scroll: [.custom(CustomSlotID("s1")), .pinnedMacro(MacroID("m1"))])
        XCTAssertTrue(layout.isValid)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(KeybarLayout.self, from: data), layout)
    }

    // MARK: - KeybarLibrary registry

    func testEmptyLibraryHasNoEntries() {
        XCTAssertTrue(KeybarLibrary.empty.macros.isEmpty)
        XCTAssertTrue(KeybarLibrary.empty.customSlots.isEmpty)
    }

    func testLookupReturnsEntryAndNilForAbsent() {
        var lib = KeybarLibrary.empty
        lib.upsertMacro(mDeploy)
        lib.upsertCustomSlot(slotKc)
        XCTAssertEqual(lib.macro(MacroID("m-deploy")), mDeploy)
        XCTAssertEqual(lib.customSlot(CustomSlotID("s-kc")), slotKc)
        XCTAssertNil(lib.macro(MacroID("nope")))
        XCTAssertNil(lib.customSlot(CustomSlotID("nope")))
    }

    func testUpsertAddsThenUpdatesInPlace() {
        var lib = KeybarLibrary.empty
        lib.upsertMacro(mDeploy)
        XCTAssertEqual(lib.macros.count, 1)
        var renamed = mDeploy
        renamed.name = "Deploy prod"
        lib.upsertMacro(renamed)
        XCTAssertEqual(lib.macros.count, 1, "same id should update, not append")
        XCTAssertEqual(lib.macro(MacroID("m-deploy"))?.name, "Deploy prod")
    }

    func testRemoveDeletesById() {
        var lib = KeybarLibrary.empty
        lib.upsertMacro(mDeploy)
        lib.removeMacro(MacroID("m-deploy"))
        XCTAssertNil(lib.macro(MacroID("m-deploy")))
    }

    // MARK: - KeybarSettings integration + back-compat

    func testDefaultSettingsLibraryIsEmpty() {
        XCTAssertEqual(KeybarSettings.default.library, .empty)
    }

    func testSettingsRoundTripsWithLibrary() throws {
        var settings = KeybarSettings.default
        settings.library.upsertMacro(mDeploy)
        settings.library.upsertCustomSlot(slotKc)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(KeybarSettings.self, from: data), settings)
    }

    func testPre4d2SettingsBlobDecodesWithEmptyLibrary() throws {
        // A persisted blob written before 4d-2 has no "library" key. It must still
        // decode (and not reset the user's layout) — library defaults to empty.
        let oldBlob = Data("""
        {"layout":{"locked":[{"kind":"escPill"},{"kind":"pad"}],
                   "scroll":[{"kind":"symbol","value":"/"}]},
         "direction":"lockedRight"}
        """.utf8)
        let decoded = try JSONDecoder().decode(KeybarSettings.self, from: oldBlob)
        XCTAssertEqual(decoded.library, .empty)
        XCTAssertEqual(decoded.direction, .lockedRight)
        XCTAssertEqual(decoded.layout.scroll, [.symbol("/")])
    }
}
