// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure checks for the private gesture bindings. The real-tmux behavior is covered by
/// `TmuxGestureBindingsIntegrationTests`.
final class TmuxGestureBindingsTests: XCTestCase {
    /// The shell script derives slot = 900 + position in the `for` list, and the list is
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
        let expected = #"sh -c 'S=semicolyn;printf "SEMICOLYN_%s\r" LAUNCH;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";i=0;for c in "split-window -h" "split-window -v" kill-pane new-window "resize-pane -Z" next-window previous-window "select-pane -t +";do n=$((900+i));k=$((9900+i));v=$(tmux show -sv "user-keys[$n]" 2>/dev/null);case "$v" in ""|*"[$k~")tmux set -s "user-keys[$n]" "$(printf "\033[$k~")";tmux bind -n "User$n" $c;;esac;i=$((i+1));done;exec tmux attach-session -t "=$S"'"#
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "semicolyn"), expected)
    }

    /// The command is TYPED into an interactive shell on Mosh/ET; macOS canonical-mode
    /// lines cap at 1024 bytes (MAX_CANON). Length is 475 + name, so the built-in name
    /// gives 484 and a 1-char name gives 476.
    func testLaunchCommandLengthIsFixedOverheadPlusName() {
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "semicolyn").count, 484)
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "a").count, 476)
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
