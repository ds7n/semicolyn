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
        let expected = #"sh -c 'S=semicolyn;printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||exec tmux;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";E=$(printf "\033");Q=$(printf "\047");N=$(printf "\nx");N=${N%x};set --;i=0;U=$N$(tmux show -s user-keys 2>/dev/null)&&for c in "split-window -h" "split-window -v" kill-pane new-window "resize-pane -Z" next-window previous-window "select-pane -t +";do k=$((9900+i));for n in $((900+i)) $((800+i));do K="${N}user-keys[$n] ";v=;case "$U" in *"$K"*)v=${U#*"$K"};v=${v%%"$N"*};;esac;case "$v" in ""|"$Q$Q"|*"[$k~")set -- "$@" set -s "user-keys[$n]" "$E[$k~" \; bind -n "User$n" $c \;;break;;esac;done;i=$((i+1));done;exec tmux "$@" attach-session -t "=$S"'"#
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "semicolyn"), expected)
    }

    /// The command is TYPED into an interactive shell on Mosh/ET; macOS canonical-mode
    /// lines cap at 1024 bytes (MAX_CANON). Length is 698 + name, so the built-in name
    /// gives 707 and a 1-char name gives 699.
    func testLaunchCommandLengthIsFixedOverheadPlusName() {
        let builtIn = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(builtIn.count, 707)
        XCTAssertEqual(builtIn.utf8.count, 707)
        XCTAssertLessThan(builtIn.utf8.count, 1024)
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "a").count, 699)
    }

    /// Every tmux client spawn costs a round trip before tmux paints, so the launch is
    /// batched: has-session, new-session (only if absent), ONE `show` of all slots, and
    /// ONE final `exec tmux` that carries every set/bind plus `attach-session`. The early
    /// `exec tmux;` (tmux-missing diagnostic) has no argument, so it is not counted. A
    /// regression back to per-action `show`/`set`/`bind` calls fails here.
    func testLaunchCommandSpawnsExactlyFourTmuxClients() {
        let cmd = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(tmuxInvocations(in: cmd),
                       ["tmux has-session", "tmux new-session", "tmux show", #"exec tmux "$@""#])
        XCTAssertFalse(cmd.contains("show -sv"))
        XCTAssertFalse(cmd.contains("tmux set"))
        XCTAssertFalse(cmd.contains("tmux bind"))
    }

    /// The per-action loop decides every slot in pure sh: no tmux spawn inside it.
    func testLaunchCommandLoopBodySpawnsNoTmux() throws {
        let cmd = plainTmuxLaunchCommand(sessionName: "semicolyn")
        let loopStart = try XCTUnwrap(cmd.range(of: "for c in "))
        let loopEnd = try XCTUnwrap(cmd.range(of: ";done;exec tmux"))
        let body = cmd[loopStart.upperBound..<loopEnd.lowerBound]
        XCTAssertFalse(body.contains("tmux"), "tmux spawned inside the per-action loop: \(body)")
    }

    /// The `tmux` command words at command position (start of a `;`/`|`/`&`/`(`-separated
    /// segment), with an `exec ` prefix kept, each trimmed to its first two words after
    /// any `exec`.
    private func tmuxInvocations(in cmd: String) -> [String] {
        cmd.split(whereSeparator: { ";|&()".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("tmux ") || $0.hasPrefix("exec tmux ") }
            .map { seg in
                let words = seg.split(separator: " ")
                return words.prefix(words.first == "exec" ? 3 : 2).joined(separator: " ")
            }
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
