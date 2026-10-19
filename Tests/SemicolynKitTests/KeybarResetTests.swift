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
