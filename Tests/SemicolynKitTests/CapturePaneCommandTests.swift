// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Builder for the `capture-pane` history-seed command (escapes kept, no join).
final class CapturePaneCommandTests: XCTestCase {
    // EP: a normal line count → -S -<N>, escapes (-e), print (-p), pane target %<raw>.
    func testBuildsNormalCapture() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 3), lines: 5000),
            "capture-pane -p -e -S -5000 -t %3")
    }

    // BVA: Int.max → whole-history shorthand `-S -` (no number).
    func testUnlimitedUsesWholeHistoryShorthand() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 7), lines: Int.max),
            "capture-pane -p -e -S - -t %7")
    }

    // BVA: lines == 1 → -S -1.
    func testSingleLine() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 0), lines: 1),
            "capture-pane -p -e -S -1 -t %0")
    }

    // Negative: lines == 0 → nil (seeding disabled), no command emitted.
    func testZeroLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: 0))
    }

    // Negative: negative lines → nil (defensive).
    func testNegativeLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: -10))
    }

    // No -J (join): the command must NOT contain -J (preserve tmux wrapping).
    func testNoJoinFlag() {
        let cmd = capturePaneCommand(paneID: PaneID(raw: 1), lines: 100) ?? ""
        XCTAssertFalse(cmd.contains("-J"), "capture must not join wrapped lines: \(cmd)")
    }

    // Reconstruct: joins content lines with \n + trailing \n; escapes preserved.
    func testReconstructJoinsContentLines() {
        let out = reconstructHistory(fromLines: ["\u{1b}[31mred\u{1b}[39m", "plain"])
        XCTAssertEqual(out, Array("\u{1b}[31mred\u{1b}[39m\nplain\n".utf8))
    }

    // Trailing blank lines (capture-pane bottom padding) are trimmed.
    func testReconstructTrimsTrailingBlanks() {
        let out = reconstructHistory(fromLines: ["a", "b", "", "   ", ""])
        XCTAssertEqual(out, Array("a\nb\n".utf8))
    }

    // All-blank input → empty (no spurious newline).
    func testReconstructAllBlankIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: ["", "  "]), [])
    }

    // Empty input → empty.
    func testReconstructEmptyIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: []), [])
    }

    // Interior blank lines are KEPT (only trailing trimmed).
    func testReconstructKeepsInteriorBlanks() {
        let out = reconstructHistory(fromLines: ["a", "", "b"])
        XCTAssertEqual(out, Array("a\n\nb\n".utf8))
    }
}
