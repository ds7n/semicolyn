// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// D-3: "Reset Keybar…" restores the layout, swipes and the hardware-keyboard
/// toggle, and keeps the macro / gesture-key library.
final class KeybarResetTests: XCTestCase {
    private let deploy = Macro(id: MacroID("m-deploy"), name: "Deploy",
                               body: [MacroEvent(key: .char("d")), MacroEvent(key: .enter)])
    private let logs = Macro(id: MacroID("m-logs"), name: "Logs", body: [MacroEvent(key: .char("l"))])
    private let gesture = CustomSlot(id: CustomSlotID("s-kc"), label: "kc",
                                     tap: GestureBinding(macro: MacroID("m-deploy")),
                                     longPress: GestureBinding(macro: MacroID("m-logs")))

    private func customized() -> KeybarSettings {
        KeybarSettings(
            layout: KeybarLayout(left: [.escPill, .custom(CustomSlotID("s-kc"))],
                                 middle: [.pinnedMacro(MacroID("m-deploy")), .symbol("~")],
                                 right: [.pad, .tab]),
            library: KeybarLibrary(macros: [deploy, logs], customSlots: [gesture]),
            hideKeybarWithHardwareKeyboard: true,
            fixedKeySecondaries: [.symbol("-"): SwipeSecondaries(up: .literal("_"))])
    }

    func testResetKeepsEveryMacroAndGestureKey() {
        let reset = customized().resettingKeepingLibrary()
        XCTAssertEqual(reset.library.macros, [deploy, logs])
        XCTAssertEqual(reset.library.customSlots, [gesture])
    }

    func testResetRestoresLayoutSwipesAndHardwareToggle() {
        let reset = customized().resettingKeepingLibrary()
        XCTAssertEqual(reset.layout, KeybarLayout.default)
        XCTAssertEqual(reset.fixedKeySecondaries, [:])
        XCTAssertFalse(reset.hideKeybarWithHardwareKeyboard)
    }

    func testResetEqualsDefaultExceptLibrary() {
        let original = customized()
        var expected = KeybarSettings.default
        expected.library = original.library
        XCTAssertEqual(original.resettingKeepingLibrary(), expected)
        XCTAssertNotEqual(original.resettingKeepingLibrary(), KeybarSettings.default,
                          "a reset that drops the library would equal .default")
    }

    func testResetOfDefaultsIsDefaults() {
        XCTAssertEqual(KeybarSettings.default.resettingKeepingLibrary(), KeybarSettings.default)
    }
}

/// M-4: Settings > Macros confirms deleting a macro only when keybar keys use it.
final class MacroUsageTests: XCTestCase {
    private let a = MacroID("a"), b = MacroID("b"), c = MacroID("c")

    private func settings() -> KeybarSettings {
        let macros = [a, b, c].map { Macro(id: $0, name: $0.raw, body: [MacroEvent(key: .char("x"))]) }
        // Gesture key 1 binds `a` on two gestures (counts once); gesture key 2 binds `a` and `b`.
        let g1 = CustomSlot(id: CustomSlotID("g1"), tap: GestureBinding(macro: a), longPress: GestureBinding(macro: a))
        let g2 = CustomSlot(id: CustomSlotID("g2"), swipeUp: GestureBinding(macro: b), swipeDown: GestureBinding(macro: a))
        return KeybarSettings(
            layout: KeybarLayout(left: [.escPill, .modifier], middle: [.pinnedMacro(a), .custom(CustomSlotID("g1"))],
                                 right: [.pad]),
            library: KeybarLibrary(macros: macros, customSlots: [g1, g2]))
    }

    func testCountsPinnedKeyAndEachGestureKeyOnce() {
        XCTAssertEqual(settings().keyCount(using: a), 3)   // pinned + g1 + g2
    }

    func testGestureKeyOnlyUse() {
        XCTAssertEqual(settings().keyCount(using: b), 1)
    }

    func testUnusedMacroCountsZero() {
        XCTAssertEqual(settings().keyCount(using: c), 0)
        XCTAssertEqual(settings().keyCount(using: MacroID("missing")), 0)
    }

    func testUsageMessagePluralization() {
        XCTAssertEqual(macroDeleteUsageMessage(keyCount: 1), "It's used by 1 keybar key.")
        XCTAssertEqual(macroDeleteUsageMessage(keyCount: 2), "It's used by 2 keybar keys.")
    }
}
