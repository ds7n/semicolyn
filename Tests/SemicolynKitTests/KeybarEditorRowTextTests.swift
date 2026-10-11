// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarEditorRowTextTests: XCTestCase {

    private let deploy = Macro(id: MacroID("m-deploy"), name: "deploy", body: [])
    private let push = Macro(id: MacroID("m-push"), name: "git push", body: [])
    private let logs = Macro(id: MacroID("m-logs"), name: "logs", body: [])

    private func settings(slots: [CustomSlot] = [],
                          overrides: [FixedKeyID: SwipeSecondaries] = [:]) -> KeybarSettings {
        KeybarSettings(library: KeybarLibrary(macros: [deploy, push, logs], customSlots: slots),
                       fixedKeySecondaries: overrides)
    }

    // MARK: - Title

    func testMacroKeyTitleUsesMacroName() {
        XCTAssertEqual(keybarEditorTitle(for: .pinnedMacro(deploy.id), library: settings().library),
                       "Macro key “deploy”")
    }

    func testMacroKeyTitleWhenMacroDeleted() {
        XCTAssertEqual(keybarEditorTitle(for: .pinnedMacro(MacroID("gone")), library: settings().library),
                       "Macro key (missing macro)")
    }

    func testGestureKeyTitleUsesResolvedLabel() {
        let key = CustomSlot(id: CustomSlotID("g1"), label: "ops", tap: GestureBinding(macro: deploy.id))
        XCTAssertEqual(keybarEditorTitle(for: .custom(key.id), library: settings(slots: [key]).library),
                       "Gesture key “ops”")
    }

    func testGestureKeyTitleFallsBackToTapMacroName() {
        let key = CustomSlot(id: CustomSlotID("g1"), tap: GestureBinding(macro: deploy.id))
        XCTAssertEqual(keybarEditorTitle(for: .custom(key.id), library: settings(slots: [key]).library),
                       "Gesture key “deploy”")
    }

    func testGestureKeyTitleWhenKeyMissing() {
        XCTAssertEqual(keybarEditorTitle(for: .custom(CustomSlotID("nope")), library: settings().library),
                       "Gesture key (missing)")
    }

    func testBuiltInTitles() {
        let lib = KeybarLibrary.empty
        XCTAssertEqual(keybarEditorTitle(for: .escPill, library: lib), "Esc pill")
        XCTAssertEqual(keybarEditorTitle(for: .pad, library: lib), "Pad (arrows + pane)")
        XCTAssertEqual(keybarEditorTitle(for: .modifier, library: lib), "Modifier (Ctrl/Alt/Shift)")
        XCTAssertEqual(keybarEditorTitle(for: .tab, library: lib), "Tab")
        XCTAssertEqual(keybarEditorTitle(for: .fn, library: lib), "Fn (function keys)")
        XCTAssertEqual(keybarEditorTitle(for: .symbol("/"), library: lib), "Symbol “/”")
    }

    // MARK: - Detail: fixed keys

    func testSymbolDetailShowsBuiltInDefault() {
        XCTAssertEqual(keybarEditorDetail(for: .symbol("/"), settings: settings()), "↑ \\   ↓ none")
    }

    func testSymbolDetailShowsUserOverrideInsteadOfDefault() {
        let s = settings(overrides: [.symbol("/"): SwipeSecondaries(up: .literal("//"), down: .literal("./"))])
        XCTAssertEqual(keybarEditorDetail(for: .symbol("/"), settings: s), "↑ //   ↓ ./")
    }

    func testSymbolWithNoSecondariesShowsNoneBothWays() {
        XCTAssertEqual(keybarEditorDetail(for: .symbol("("), settings: settings()), "↑ none   ↓ none")
    }

    func testTabDetailShowsShiftTabGlyph() {
        XCTAssertEqual(keybarEditorDetail(for: .tab, settings: settings()), "↑ ⇤   ↓ none")
    }

    func testOverrideClearingDefaultShowsNone() {
        let s = settings(overrides: [.tab: SwipeSecondaries()])
        XCTAssertEqual(keybarEditorDetail(for: .tab, settings: s), "↑ none   ↓ none")
    }

    // MARK: - Detail: macro and gesture keys

    func testMacroKeyDetailShowsTap() {
        XCTAssertEqual(keybarEditorDetail(for: .pinnedMacro(push.id), settings: settings()), "Tap: git push")
    }

    func testMacroKeyDetailNilWhenMacroDeleted() {
        XCTAssertNil(keybarEditorDetail(for: .pinnedMacro(MacroID("gone")), settings: settings()))
    }

    func testGestureKeyDetailListsOnlyBoundGesturesInOrder() {
        let key = CustomSlot(id: CustomSlotID("g1"),
                             tap: GestureBinding(macro: deploy.id),
                             swipeUp: GestureBinding(macro: push.id),
                             longPress: GestureBinding(macro: logs.id))
        XCTAssertEqual(keybarEditorDetail(for: .custom(key.id), settings: settings(slots: [key])),
                       "Tap: deploy · ↑ git push · Hold: logs")
    }

    func testGestureKeyDetailAllFourGestures() {
        let key = CustomSlot(id: CustomSlotID("g1"),
                             tap: GestureBinding(macro: deploy.id),
                             swipeUp: GestureBinding(macro: push.id),
                             swipeDown: GestureBinding(macro: logs.id),
                             longPress: GestureBinding(macro: deploy.id))
        XCTAssertEqual(keybarEditorDetail(for: .custom(key.id), settings: settings(slots: [key])),
                       "Tap: deploy · ↑ git push · ↓ logs · Hold: deploy")
    }

    func testGestureKeyDetailMarksDeletedMacro() {
        let key = CustomSlot(id: CustomSlotID("g1"), swipeDown: GestureBinding(macro: MacroID("gone")))
        XCTAssertEqual(keybarEditorDetail(for: .custom(key.id), settings: settings(slots: [key])),
                       "↓ missing")
    }

    func testGestureKeyDetailNilWhenKeyMissing() {
        XCTAssertNil(keybarEditorDetail(for: .custom(CustomSlotID("nope")), settings: settings()))
    }

    // MARK: - Detail: built-ins without secondaries

    func testBuiltInsWithoutSecondariesHaveNoDetail() {
        for slot in [KeybarSlot.escPill, .pad, .modifier, .fn] {
            XCTAssertNil(keybarEditorDetail(for: slot, settings: settings()), "\(slot)")
        }
    }
}
