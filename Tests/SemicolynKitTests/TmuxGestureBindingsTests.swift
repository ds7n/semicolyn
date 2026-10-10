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
        let expected = #"sh -c 'S=semicolyn;printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||exec tmux;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";E=$(printf "\033");Q=$(printf "\047");N=$(printf "\nx");N=${N%x};set --;i=0;U=$N$(tmux show -s user-keys 2>/dev/null)&&for c in "split-window -h" "split-window -v" kill-pane new-window "resize-pane -Z" next-window previous-window "select-pane -t +";do k=$((9900+i));for n in $((900+i)) $((800+i));do K="${N}user-keys[$n] ";v=;case "$U" in *"$K"*)v=${U#*"$K"};v=${v%%"$N"*};;esac;case "$v" in ""|"$Q$Q"|*"[$k~"|*"[$k~\"")set -- "$@" set -s "user-keys[$n]" "$E[$k~" \; bind -n "User$n" $c \;;break;;esac;done;i=$((i+1));done;[ $# -gt 0 ]&&tmux "$@" 2>/dev/null;exec tmux attach-session -t "=$S"'"#
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "semicolyn"), expected)
    }

    /// The command is TYPED into an interactive shell on Mosh/ET; macOS canonical-mode
    /// lines cap at 1024 bytes (MAX_CANON). Length is 739 + name, so the built-in name
    /// gives 748 and a 1-char name gives 740.
    func testLaunchCommandLengthIsFixedOverheadPlusName() {
        let builtIn = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(builtIn.count, 748)
        XCTAssertEqual(builtIn.utf8.count, 748)
        XCTAssertLessThan(builtIn.utf8.count, 1024)
        XCTAssertEqual(plainTmuxLaunchCommand(sessionName: "a").count, 740)
    }

    /// Every tmux client spawn costs a round trip before tmux paints, so the launch is
    /// batched: has-session, new-session (only if absent), ONE `show` of all slots, ONE
    /// call carrying every set/bind (skipped when there are none), and the final
    /// `exec tmux attach-session`. The early `exec tmux;` (tmux-missing diagnostic) has no
    /// argument, so it is not counted. A regression back to per-action
    /// `show`/`set`/`bind` calls fails here.
    func testLaunchCommandSpawnsAtMostFiveTmuxClients() {
        let cmd = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(tmuxInvocations(in: cmd),
                       ["tmux has-session", "tmux new-session", "tmux show", #"tmux "$@""#,
                        "exec tmux attach-session"])
        XCTAssertFalse(cmd.contains("show -sv"))
        XCTAssertFalse(cmd.contains("tmux set"))
        XCTAssertFalse(cmd.contains("tmux bind"))
    }

    /// tmux aborts a `\;` chain at its first failing command, so `attach-session` must
    /// NOT ride in the set/bind chain: a failed bind would strand the user at a bare
    /// shell. The chain runs as its own call with failure ignored (`;`, not `&&`), only
    /// when it is non-empty, and the script always ends with a standalone attach.
    func testAttachIsItsOwnExecNeverChainedAfterBindings() {
        let cmd = plainTmuxLaunchCommand(sessionName: "semicolyn")
        XCTAssertTrue(cmd.hasSuffix(#";done;[ $# -gt 0 ]&&tmux "$@" 2>/dev/null;exec tmux attach-session -t "=$S"'"#))
        XCTAssertFalse(cmd.contains(#""$@" attach-session"#))
        XCTAssertEqual(cmd.components(separatedBy: "attach-session").count, 2)
    }

    /// The per-action loop decides every slot in pure sh: no tmux spawn inside it.
    func testLaunchCommandLoopBodySpawnsNoTmux() throws {
        let cmd = plainTmuxLaunchCommand(sessionName: "semicolyn")
        let loopStart = try XCTUnwrap(cmd.range(of: "for c in "))
        let loopEnd = try XCTUnwrap(cmd.range(of: ";done;[ $#"))
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

    // MARK: - Direct launch (mosh-server session command)

    private let directExpected = #"sh -c 'S=semicolyn;printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||{ printf "SEMICOLYN_%s\n" NOTMUX;exec "${SHELL:-sh}" -l;};tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";E=$(printf "\033");Q=$(printf "\047");N=$(printf "\nx");N=${N%x};set --;i=0;U=$N$(tmux show -s user-keys 2>/dev/null)&&for c in "split-window -h" "split-window -v" kill-pane new-window "resize-pane -Z" next-window previous-window "select-pane -t +";do k=$((9900+i));for n in $((900+i)) $((800+i));do K="${N}user-keys[$n] ";v=;case "$U" in *"$K"*)v=${U#*"$K"};v=${v%%"$N"*};;esac;case "$v" in ""|"$Q$Q"|*"[$k~"|*"[$k~\"")set -- "$@" set -s "user-keys[$n]" "$E[$k~" \; bind -n "User$n" $c \;;break;;esac;done;i=$((i+1));done;[ $# -gt 0 ]&&tmux "$@" 2>/dev/null;tmux attach-session -t "=$S";exec "${SHELL:-sh}" -l'"#

    func testDirectLaunchCommandExactForDefaultSession() {
        XCTAssertEqual(plainTmuxDirectLaunchCommand(sessionName: "semicolyn"), directExpected)
    }

    /// Not typed (it rides the SSH exec as mosh-server's command), but pinned so any
    /// change to the script is deliberate: 805 + name length.
    func testDirectLaunchCommandLengthIsFixedOverheadPlusName() {
        XCTAssertEqual(plainTmuxDirectLaunchCommand(sessionName: "semicolyn").utf8.count, 814)
        XCTAssertEqual(plainTmuxDirectLaunchCommand(sessionName: "a").utf8.count, 806)
    }

    func testDirectLaunchCommandEmbedsSessionName() {
        XCTAssertTrue(plainTmuxDirectLaunchCommand(sessionName: "work-1").hasPrefix("sh -c 'S=work-1;printf "))
    }

    /// The whole script is ONE single-quoted `sh -c` argument, so it must contain no
    /// single quote of its own: exactly the two delimiters, at the ends.
    func testDirectLaunchCommandHasOnlyTheTwoOuterSingleQuotes() {
        let cmd = plainTmuxDirectLaunchCommand(sessionName: "semicolyn")
        XCTAssertEqual(cmd.filter { $0 == "'" }.count, 2)
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.hasSuffix("'"))
    }

    /// Detaching or exiting tmux must leave the user at their login shell, not end the
    /// Mosh session: attach is NOT exec'd, and is followed by the shell fallback.
    func testDirectAttachIsNotExecAndIsFollowedByLoginShell() {
        let cmd = plainTmuxDirectLaunchCommand(sessionName: "semicolyn")
        XCTAssertTrue(cmd.hasSuffix(#"&&tmux "$@" 2>/dev/null;tmux attach-session -t "=$S";exec "${SHELL:-sh}" -l'"#))
        XCTAssertFalse(cmd.contains("exec tmux"))
        XCTAssertEqual(cmd.components(separatedBy: "attach-session").count, 2)
    }

    /// tmux missing from the non-interactive PATH prints the distinct marker and hands the
    /// user their interactive login shell instead of a `tmux: not found` line.
    func testDirectMissingTmuxPrintsMarkerThenExecsLoginShell() {
        let cmd = plainTmuxDirectLaunchCommand(sessionName: "semicolyn")
        XCTAssertTrue(cmd.contains(#"command -v tmux >/dev/null||{ printf "SEMICOLYN_%s\n" NOTMUX;exec "${SHELL:-sh}" -l;};"#))
        XCTAssertFalse(containsPlainTmuxNoTmuxMarker(cmd))   // printf-split, like the sentinel
    }

    /// Same batched spawn budget as the in-band launch: the attach is a plain call.
    func testDirectLaunchCommandSpawnsAtMostFiveTmuxClients() {
        XCTAssertEqual(tmuxInvocations(in: plainTmuxDirectLaunchCommand(sessionName: "semicolyn")),
                       ["tmux has-session", "tmux new-session", "tmux show", #"tmux "$@""#,
                        "tmux attach-session"])
    }

    /// The session-create + binding body is SHARED with the in-band launch, not a copy:
    /// both variants carry the identical text from `tmux has-session` through the
    /// set/bind call, for any session name.
    func testDirectAndInBandShareTheBindingBody() throws {
        for name in ["semicolyn", "a", "work-1"] {
            let inBand = try sharedBody(plainTmuxLaunchCommand(sessionName: name))
            let direct = try sharedBody(plainTmuxDirectLaunchCommand(sessionName: name))
            XCTAssertEqual(direct, inBand)
            XCTAssertTrue(inBand.hasPrefix(#"tmux has-session -t "=$S""#), inBand)
            XCTAssertTrue(inBand.hasSuffix(#"&&tmux "$@" 2>/dev/null"#), inBand)
        }
    }

    func testNoTmuxMarkerDetection() {
        XCTAssertEqual(plainTmuxNoTmuxMarker, "SEMICOLYN_NOTMUX")
        XCTAssertTrue(containsPlainTmuxNoTmuxMarker("SEMICOLYN_LAUNCH\rSEMICOLYN_NOTMUX\r\n$ "))
        XCTAssertFalse(containsPlainTmuxNoTmuxMarker(""))
        XCTAssertFalse(containsPlainTmuxNoTmuxMarker("SEMICOLYN_NOTMU"))   // truncated chunk
        XCTAssertFalse(containsPlainTmuxNoTmuxMarker("SEMICOLYN_LAUNCH\r"))   // sentinel only
        // The in-band launch never prints it, so its tmux-missing path stays the probe's.
        XCTAssertFalse(containsPlainTmuxNoTmuxMarker(plainTmuxLaunchCommand(sessionName: "semicolyn")))
    }

    /// The text from `tmux has-session` up to and including the set/bind call.
    private func sharedBody(_ cmd: String) throws -> String {
        let start = try XCTUnwrap(cmd.range(of: "tmux has-session"))
        let end = try XCTUnwrap(cmd.range(of: #"tmux "$@" 2>/dev/null"#))
        return String(cmd[start.lowerBound..<end.upperBound])
    }
}
