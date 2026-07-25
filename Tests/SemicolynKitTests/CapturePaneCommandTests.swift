// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Builder for the `capture-pane` history-seed command (escapes kept, joins wrapped
/// rows via `-J` so history captured at one width re-wraps correctly at ours).
final class CapturePaneCommandTests: XCTestCase {
    // EP: a normal line count → -S -<N>, escapes (-e), join (-J), print (-p), pane %<raw>.
    func testBuildsNormalCapture() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 3), lines: 5000),
            "capture-pane -p -e -J -S -5000 -t %3")
    }

    // BVA: Int.max → whole-history shorthand `-S -` (no number).
    func testUnlimitedUsesWholeHistoryShorthand() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 7), lines: Int.max),
            "capture-pane -p -e -J -S - -t %7")
    }

    // BVA: lines == 1 → -S -1.
    func testSingleLine() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 0), lines: 1),
            "capture-pane -p -e -J -S -1 -t %0")
    }

    // Negative: lines == 0 → nil (seeding disabled), no command emitted.
    func testZeroLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: 0))
    }

    // Negative: negative lines → nil (defensive).
    func testNegativeLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: -10))
    }

    // Join (-J): the command MUST contain -J so tmux joins its soft-wrapped rows into
    // logical lines; without it, history captured at a wider width re-wraps (staircases)
    // when replayed into our narrower buffer (device bug 2026-07-23).
    func testHasJoinFlag() {
        let cmd = capturePaneCommand(paneID: PaneID(raw: 1), lines: 100) ?? ""
        XCTAssertTrue(cmd.contains(" -J "), "capture must join wrapped lines (-J): \(cmd)")
    }

    // Reconstruct: joins content lines with CR-LF and does NOT append a trailing newline;
    // escapes preserved. CR-LF (not bare LF) is required so SwiftTerm returns the cursor to
    // column 0 per line (lineFeedMode/LNM is OFF by default → bare LF would staircase the
    // history). The LAST captured line is the pane's current line (the live shell prompt);
    // appending a trailing CR-LF would push the cursor to a fresh blank line BELOW the
    // prompt, stranding it there (device bug 2026-07-25: switched-to window put the prompt
    // on its own line with the cursor below it, and the extra line showed as a gap above the
    // keybar). So the cursor must rest AT the end of the last line, not below it.
    func testReconstructJoinsContentLinesWithCRLFNoTrailingNewline() {
        let out = reconstructHistory(fromLines: ["\u{1b}[31mred\u{1b}[39m", "plain"])
        XCTAssertEqual(out, Array("\u{1b}[31mred\u{1b}[39m\r\nplain".utf8))
    }

    // Single content line → no CR-LF at all; the cursor rests at the end of that line (the
    // prompt), not on a new line below it.
    func testReconstructSingleLineHasNoTrailingNewline() {
        let out = reconstructHistory(fromLines: ["user@host:~$"])
        XCTAssertEqual(out, Array("user@host:~$".utf8))
    }

    // Trailing blank lines (capture-pane bottom padding) are trimmed; CR-LF between rows,
    // none after the last content row.
    func testReconstructTrimsTrailingBlanks() {
        let out = reconstructHistory(fromLines: ["a", "b", "", "   ", ""])
        XCTAssertEqual(out, Array("a\r\nb".utf8))
    }

    // All-blank input → empty (no spurious newline).
    func testReconstructAllBlankIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: ["", "  "]), [])
    }

    // Empty input → empty.
    func testReconstructEmptyIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: []), [])
    }

    // Interior blank lines are KEPT (only trailing trimmed); each break is CR-LF; no
    // trailing newline after the last content line.
    func testReconstructKeepsInteriorBlanks() {
        let out = reconstructHistory(fromLines: ["a", "", "b"])
        XCTAssertEqual(out, Array("a\r\n\r\nb".utf8))
    }
}
