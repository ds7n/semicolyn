// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Hardware-keyboard window/pane shortcuts drive plain tmux through the gesture
/// layer's private bindings, only while plain tmux is attached.
final class KeyboardTmuxActionTests: XCTestCase {
    /// Resolve a real chord through the catalog, then map it, so a catalog rebinding
    /// that breaks a shortcut fails here too.
    private func action(_ input: String, shift: Bool = false, tmux: Bool = true) -> TmuxAction? {
        guard let command = KeyboardCommandCatalog.command(
            for: KeyboardChord(input: input, command: true, shift: shift)) else {
            XCTFail("chord \(input) shift=\(shift) is unbound")
            return nil
        }
        return keyboardTmuxAction(for: command, plainTmuxAttached: tmux)
    }

    // MARK: - tmux attached: each shortcut maps to its action

    func testCommandTIsNewWindow() {
        XCTAssertEqual(action("t"), .newWindow)
    }

    func testShiftCommandRightBracketIsNextWindow() {
        XCTAssertEqual(action("]", shift: true), .nextWindow)
    }

    func testShiftCommandLeftBracketIsPreviousWindow() {
        XCTAssertEqual(action("[", shift: true), .previousWindow)
    }

    func testCommandRightBracketIsNextPane() {
        // The catalog binds ⌘] to "Next Pane" (⇧⌘] is "Next Window").
        XCTAssertEqual(action("]"), .cyclePane)
    }

    func testCommandDAndPipeSplitSideBySide() {
        XCTAssertEqual(action("d"), .splitHorizontal)
        XCTAssertEqual(action("|"), .splitHorizontal)
        XCTAssertEqual(TmuxAction.splitHorizontal.command, "split-window -h")
    }

    func testShiftCommandDAndMinusSplitBelow() {
        XCTAssertEqual(action("d", shift: true), .splitVertical)
        XCTAssertEqual(action("-"), .splitVertical)
        XCTAssertEqual(TmuxAction.splitVertical.command, "split-window -v")
    }

    /// The exact bytes each mapped shortcut writes (the action's private sequence).
    func testMappedShortcutsWriteExactSequences() {
        XCTAssertEqual(action("t")?.gestureSequence, Array("\u{1b}[9903~".utf8))
        XCTAssertEqual(action("]", shift: true)?.gestureSequence, Array("\u{1b}[9905~".utf8))
        XCTAssertEqual(action("[", shift: true)?.gestureSequence, Array("\u{1b}[9906~".utf8))
        XCTAssertEqual(action("]")?.gestureSequence, Array("\u{1b}[9907~".utf8))
        XCTAssertEqual(action("d")?.gestureSequence, Array("\u{1b}[9900~".utf8))
        XCTAssertEqual(action("-")?.gestureSequence, Array("\u{1b}[9901~".utf8))
    }

    // MARK: - tmux attached: shortcuts with no bound action stay no-ops

    func testUnboundWindowPaneShortcutsMapToNil() {
        XCTAssertNil(action("w"))            // Close Window
        XCTAssertNil(action("["))            // Previous Pane
        XCTAssertNil(action("1"))            // Switch to Window 1
        XCTAssertNil(action("9"))            // Switch to Window 9
    }

    func testNonTmuxCommandsMapToNil() {
        for command: KeyboardCommand in [.clearScreen, .copy, .paste, .newConnection,
                                         .reconnect, .openLauncher, .settings, .tips] {
            XCTAssertNil(keyboardTmuxAction(for: command, plainTmuxAttached: true), "\(command)")
        }
    }

    // MARK: - no tmux: nothing maps

    func testNoTmuxMapsEveryShortcutToNil() {
        for spec in KeyboardCommandCatalog.all {
            XCTAssertNil(keyboardTmuxAction(for: spec.command, plainTmuxAttached: false),
                         "\(spec.title) must do nothing without tmux")
        }
        XCTAssertNil(action("t", tmux: false))
        XCTAssertNil(action("d", tmux: false))
    }
}
