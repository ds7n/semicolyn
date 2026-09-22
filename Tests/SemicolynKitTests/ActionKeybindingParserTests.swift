// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Reverse-lookup: parse `tmux list-keys -T prefix` output into action->key. Matches
/// command verb + distinguishing flag, ignores trailing args (-c "#{...}"), and SKIPS
/// commands nested in display-menu/display-popup (not directly sendable).
final class ActionKeybindingParserTests: XCTestCase {
    // The user's real config: split rebound to |/- with a -c path arg.
    func testUserConfigSplitBindingsWithPathArg() {
        let out = """
        bind-key    -T prefix       -    split-window -v -c "#{pane_current_path}"
        bind-key    -T prefix       |    split-window -h -c "#{pane_current_path}"
        bind-key    -T prefix       c    new-window
        bind-key    -T prefix       x    confirm-before -p "kill?" kill-pane
        """
        let m = parseActionKeybindings(out)
        XCTAssertEqual(m[.splitVertical], "-")
        XCTAssertEqual(m[.splitHorizontal], "|")
        XCTAssertEqual(m[.newWindow], "c")
        // kill-pane appears even behind confirm-before (verb present on the line).
        XCTAssertEqual(m[.closePane], "x")
    }

    // Default bindings.
    func testDefaultBindings() {
        let out = """
        bind-key    -T prefix       %    split-window -h
        bind-key    -T prefix       "    split-window -v
        bind-key    -T prefix       z    resize-pane -Z
        bind-key    -T prefix       n    next-window
        bind-key    -T prefix       p    previous-window
        bind-key    -T prefix       o    select-pane -t :.+
        """
        let m = parseActionKeybindings(out)
        XCTAssertEqual(m[.splitHorizontal], "%")
        XCTAssertEqual(m[.splitVertical], "\"")
        XCTAssertEqual(m[.zoom], "z")
        XCTAssertEqual(m[.nextWindow], "n")
        XCTAssertEqual(m[.previousWindow], "p")
        XCTAssertEqual(m[.cyclePane], "o")
    }

    // A split-window buried in a display-menu block must NOT be matched (not a
    // directly-sendable prefix key).
    func testDisplayMenuNestedCommandsSkipped() {
        let out = """
        bind-key    -T prefix       >    display-menu -T "Menu" "Horizontal Split" h { split-window -h } Kill X { kill-pane }
        bind-key    -T prefix       |    split-window -h
        """
        let m = parseActionKeybindings(out)
        // The only usable split key is `|`, NOT `>` (the menu) and NOT `h`/`X` (menu items).
        XCTAssertEqual(m[.splitHorizontal], "|")
        // kill-pane only existed inside the menu -> not directly bound -> absent.
        XCTAssertNil(m[.closePane])
    }

    // An action with no binding at all is absent from the map.
    func testMissingActionAbsent() {
        let out = "bind-key    -T prefix       c    new-window"
        let m = parseActionKeybindings(out)
        XCTAssertNil(m[.zoom])
        XCTAssertEqual(m[.newWindow], "c")
    }

    // Default config lists the directional select-pane binds (Up/Down/Left/Right)
    // BEFORE the cycling `o` bind. First-match-wins must NOT grab a directional
    // MOVE key for cyclePane; it must resolve to the cycling bind "o".
    func testCyclePaneSkipsDirectionalBindsListedFirst() {
        let out = """
        bind-key    -T prefix       Up      select-pane -U
        bind-key    -T prefix       Down    select-pane -D
        bind-key    -T prefix       Left    select-pane -L
        bind-key    -T prefix       Right   select-pane -R
        bind-key    -T prefix       o       select-pane -t :.+
        """
        let m = parseActionKeybindings(out)
        XCTAssertEqual(m[.cyclePane], "o")
    }

    // A cycling select-pane bound to a non-default key still resolves via its
    // cycling target token, not by key identity.
    func testCyclePaneMatchesCyclingTargetToken() {
        let out = "bind-key    -T prefix       o    select-pane -t :.+"
        let m = parseActionKeybindings(out)
        XCTAssertEqual(m[.cyclePane], "o")
    }

    // Only directional select-pane binds present, no cycle bind: cyclePane must be
    // ABSENT (nil), not silently mismapped to a directional key. Absent is safer:
    // callers fall back to command-mode rather than sending the wrong direction.
    func testCyclePaneAbsentWhenOnlyDirectionalBindsPresent() {
        let out = """
        bind-key    -T prefix       Up      select-pane -U
        bind-key    -T prefix       Down    select-pane -D
        bind-key    -T prefix       Left    select-pane -L
        bind-key    -T prefix       Right   select-pane -R
        """
        let m = parseActionKeybindings(out)
        XCTAssertNil(m[.cyclePane])
    }
}
