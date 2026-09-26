// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure checks for the private gesture bindings. The real-tmux behavior is covered by
/// `TmuxGestureBindingsIntegrationTests`.
final class TmuxGestureBindingsTests: XCTestCase {
    /// The shell script derives the preferred slot = 900 + position in the `for` list, and the list is
    /// built from `allCases` order, so slots MUST be contiguous 900...907 in that order.
    func testSlotsAreContiguousInDeclarationOrder() {
        XCTAssertEqual(TmuxAction.allCases.map(\.bindingSlot), Array(900...907))
    }

    func testGestureSequenceExactBytesAtBothEnds() {
        // ESC [ 9 9 0 0 ~
        XCTAssertEqual(TmuxAction.splitHorizontal.gestureSequence,
                       [0x1b, 0x5b, 0x39, 0x39, 0x30, 0x30, 0x7e])
        // ESC [ 9 9 0 7 ~
        XCTAssertEqual(TmuxAction.cyclePane.gestureSequence,
                       [0x1b, 0x5b, 0x39, 0x39, 0x30, 0x37, 0x7e])
    }

    func testEveryGestureSequenceIsDistinctAndSevenBytes() {
        let seqs = TmuxAction.allCases.map(\.gestureSequence)
        XCTAssertEqual(Set(seqs).count, 8)
        XCTAssertEqual(Set(seqs.map(\.count)), [7])
    }

    func testLaunchCommandExactForDefaultSession() {
        let expected = #"sh -c 'S=semicolyn;printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||exec tmux;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";i=0;for c in "split-window -h" "split-window -v" kill-pane new-window "resize-pane -Z" next-window previous-window "select-pane -t +";do k=$((9900+i));for n in $((900+i)) $((800+i));do v=$(tmux show -sv "user-keys[$n]" 2>/dev/null);case "$v" in ""|*"[$k~")tmux set -s "user-keys[$n]" "$(printf "\033[$k~")";tmux bind -n "User$n" $c;break;;esac;done;i=$((i+1));done;exec tmux attach-session -t "=$S"'"#
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "semicolyn"), expected)
    }

    /// The command is TYPED into an interactive shell on Mosh/ET; macOS canonical-mode
    /// lines cap at 1024 bytes (MAX_CANON). Length is 545 + name, so the built-in name
    /// gives 554 and a 1-char name gives 546.
    func testLaunchCommandLengthIsFixedOverheadPlusName() {
        let builtIn = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(builtIn.count, 554)
        XCTAssertEqual(builtIn.utf8.count, 554)
        XCTAssertLessThan(builtIn.utf8.count, 1024)
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "a").count, 546)
    }

    /// The script tries slot 900+i then 800+i, so the fallbacks must be contiguous
    /// 800...807 in `allCases` order, exactly 100 below each preferred slot.
    func testFallbackSlotsAreContiguous800To807() {
        XCTAssertEqual(TmuxAction.allCases.map(\.fallbackBindingSlot), Array(800...807))
    }

    func testLaunchCommandEmbedsSessionName() {
        let cmd = plainTmuxLaunchCommand(sessionName: "work-1")
        XCTAssertTrue(cmd.hasPrefix("sh -c 'S=work-1;printf "))
    }

    /// On Mosh/ET the shell ECHOES the typed command. The echo must never look like the
    /// executed sentinel, or a dead server's echo could pass the reattach liveness check.
    func testEchoedLaunchCommandDoesNotContainSentinel() {
        XCTAssertFalse(containsPlainTmuxLaunchSentinel(plainTmuxLaunchCommand(sessionName: "semicolyn")))
    }

    func testSentinelDetection() {
        XCTAssertTrue(containsPlainTmuxLaunchSentinel("junk\r\nSEMICOLYN_LAUNCH\r\u{1b}[?1049h"))
        XCTAssertFalse(containsPlainTmuxLaunchSentinel(""))
        XCTAssertFalse(containsPlainTmuxLaunchSentinel("SEMICOLYN_LAUNC"))   // truncated chunk
        XCTAssertFalse(containsPlainTmuxLaunchSentinel("SEMICOLYN_PREFIX=C-a"))   // old sentinel
    }
}
