// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The hardware-keyboard Cmd-shortcut catalog (Phase 4e): the data behind the
/// `UIKeyCommand` registrations and the ⌘-hold discoverability HUD. The App tier
/// turns each entry into a `UIKeyCommand`; this layer is the pure source of truth
/// (external-keyboard spec "Cmd-shortcut map").
final class KeyboardCommandTests: XCTestCase {
    private func resolve(command input: String, shift: Bool = false) -> KeyboardCommand? {
        KeyboardCommandCatalog.command(for:
            KeyboardChord(input: input, command: true, shift: shift))
    }

    // MARK: - Representative resolutions

    func testNewWindowIsCommandT() {
        XCTAssertEqual(resolve(command: "t"), .newWindow)
    }

    func testCloseWindowIsCommandW() {
        XCTAssertEqual(resolve(command: "w"), .closeWindow)
    }

    func testSettingsIsCommandComma() {
        XCTAssertEqual(resolve(command: ","), .settings)
    }

    func testTipsIsCommandQuestion() {
        XCTAssertEqual(resolve(command: "?"), .tips)
    }

    func testDisconnectIsShiftCommandW() {
        XCTAssertEqual(resolve(command: "w", shift: true), .disconnect)
        // ⌘W (no shift) is still Close Window: the two do not collide.
        XCTAssertEqual(resolve(command: "w"), .closeWindow)
    }

    func testDisconnectHudTitle() {
        let titles = KeyboardCommandCatalog.all.filter { $0.command == .disconnect }.map(\.title)
        XCTAssertEqual(titles, ["Disconnect"])
    }

    func testSplitTitlesMatchThePaneDialog() {
        // M-99: shortcut names match the Pad long-press dialog ("Split Right" / "Split Down").
        let right = KeyboardCommandCatalog.all.filter { $0.command == .splitVertical }.map(\.title)
        let down = KeyboardCommandCatalog.all.filter { $0.command == .splitHorizontal }.map(\.title)
        XCTAssertEqual(right, ["Split Right", "Split Right"])
        XCTAssertEqual(down, ["Split Down", "Split Down"])
    }

    func testNoZoomShortcutsAndMinusStaysSplitDown() {
        // D-12: pinch only; ⌘= and ⌘0 are unbound, ⌘- keeps the split alias.
        XCTAssertNil(resolve(command: "="))
        XCTAssertNil(resolve(command: "0"))
        XCTAssertEqual(resolve(command: "-"), .splitHorizontal)
    }

    func testLauncherIsShiftCommandP() {
        XCTAssertEqual(resolve(command: "p", shift: true), .openLauncher)
    }

    // MARK: - Window numbers (boundary values 1 and 9; 0 unbound)

    func testSwitchWindowOne() {
        XCTAssertEqual(resolve(command: "1"), .switchWindow(1))
    }

    func testSwitchWindowNine() {
        XCTAssertEqual(resolve(command: "9"), .switchWindow(9))
    }

    func testZeroIsNotAWindowShortcut() {
        XCTAssertNil(resolve(command: "0"))
    }

    // MARK: - Prev/next disambiguation by shift

    func testPrevNextWindowUseShiftBracket() {
        XCTAssertEqual(resolve(command: "[", shift: true), .prevWindow)
        XCTAssertEqual(resolve(command: "]", shift: true), .nextWindow)
    }

    func testPrevNextPaneUsePlainBracket() {
        XCTAssertEqual(resolve(command: "["), .prevPane)
        XCTAssertEqual(resolve(command: "]"), .nextPane)
    }

    // MARK: - Split aliases (two shortcuts, one action each)

    func testVerticalSplitHasTwoAliasesForOneAction() {
        XCTAssertEqual(resolve(command: "d"), .splitVertical)         // ⌘D
        XCTAssertEqual(resolve(command: "|"), .splitVertical)         // ⌘|
    }

    func testHorizontalSplitHasTwoAliasesForOneAction() {
        XCTAssertEqual(resolve(command: "d", shift: true), .splitHorizontal)  // ⇧⌘D
        XCTAssertEqual(resolve(command: "-"), .splitHorizontal)              // ⌘-
    }

    // MARK: - Negative cases

    func testUnboundChordResolvesToNil() {
        XCTAssertNil(resolve(command: "z"))
    }

    func testCharacterWithoutCommandIsNotAShortcut() {
        // A bare "t" (no Cmd) is terminal input, never a shortcut.
        XCTAssertNil(KeyboardCommandCatalog.command(for:
            KeyboardChord(input: "t", command: false)))
    }

    // MARK: - Catalog integrity

    func testEveryEntryHasANonEmptyHudTitle() {
        for entry in KeyboardCommandCatalog.all {
            XCTAssertFalse(entry.title.isEmpty, "\(entry.command) has an empty HUD title")
        }
    }

    func testNoTwoEntriesShareAChord() {
        let chords = KeyboardCommandCatalog.all.map(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "duplicate chord binding in the catalog")
    }

    func testCatalogCoversEveryDistinctAction() {
        // Each distinct action from the spec must appear at least once.
        // (⌘F/find is intentionally absent — deferred, see the external-keyboard spec.)
        let actions = Set(KeyboardCommandCatalog.all.map(\.command))
        let expected: Set<KeyboardCommand> = [
            .newWindow, .closeWindow, .switchWindow(1), .prevWindow, .nextWindow,
            .prevPane, .nextPane, .splitVertical, .splitHorizontal,
            .clearScreen, .copy, .paste, .newConnection, .reconnect, .disconnect,
            .openLauncher, .settings, .tips,
        ]
        for action in expected {
            XCTAssertTrue(actions.contains(action), "catalog is missing \(action)")
        }
    }

    func testWindowSwitchCoversOneThroughNine() {
        for n in 1...9 {
            XCTAssertEqual(resolve(command: String(n)), .switchWindow(n))
        }
    }

    // Tips and Settings > Keyboard list chords as glyphs in Apple's order (⌃⌥⇧⌘).
    func testChordGlyphs() {
        XCTAssertEqual(KeyboardChord(input: "p", command: true, shift: true).glyphs, "⇧⌘P")
        XCTAssertEqual(KeyboardChord(input: ",", command: true).glyphs, "⌘,")
        XCTAssertEqual(KeyboardChord(input: "x", command: true, shift: true, control: true, option: true).glyphs,
                       "⌃⌥⇧⌘X")
        XCTAssertEqual(KeyboardChord(input: "a").glyphs, "A")
    }
}
