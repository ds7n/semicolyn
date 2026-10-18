// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: the commit-time echo check is the transport-agnostic password
/// gate. A false `true` is a learned plaintext password, so every non-echo vector
/// is a negative that must return `false`, and the positives prove the check is
/// not simply suppressing everything.
final class CommitEchoTests: XCTestCase {

    // MARK: - rowConfirmsEcho: echoed partitions

    func testEchoed() {
        XCTAssertTrue(rowConfirmsEcho(typedLine: "ls", renderedBeforeCursor: "user@host:~$ ls"))
        XCTAssertTrue(rowConfirmsEcho(typedLine: "git status ", renderedBeforeCursor: "$ git status"))
        XCTAssertTrue(rowConfirmsEcho(typedLine: "make", renderedBeforeCursor: "$ mak"))          // 4 chars: 1 in flight ok
        XCTAssertTrue(rowConfirmsEcho(typedLine: "hello", renderedBeforeCursor: "│ > hello"))      // TUI prompt box
    }

    func testRenderedTrailingSpacesIgnored() {
        // The cursor often sits after padding; trailing blanks on screen do not matter.
        XCTAssertTrue(rowConfirmsEcho(typedLine: "ls", renderedBeforeCursor: "$ ls   "))
    }

    func testTypedTrailingSpacesIgnored() {
        // A trailing typed space leaves only a blank cell, which reads as nothing
        // after trimming; the slack must not be what saves these lines.
        XCTAssertTrue(rowConfirmsEcho(typedLine: "ls ", renderedBeforeCursor: "$ ls"))
        XCTAssertTrue(rowConfirmsEcho(typedLine: "git status  ", renderedBeforeCursor: "$ git status"))
    }

    func testExactWholeRowMatch() {
        // No prompt at all (a bare TUI input line): rendered equals typed.
        XCTAssertTrue(rowConfirmsEcho(typedLine: "x", renderedBeforeCursor: "x"))
    }

    func testSingleCharacterEchoed() {
        // Minimum non-empty line, fully echoed.
        XCTAssertTrue(rowConfirmsEcho(typedLine: "q", renderedBeforeCursor: "$ q"))
    }

    // MARK: - rowConfirmsEcho: not-echoed partitions (adversarial)

    func testNotEchoed() {
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: "Password: "))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: "Password: *******"))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "abc", renderedBeforeCursor: "$ ab"))            // 3 chars: no slack
        XCTAssertFalse(rowConfirmsEcho(typedLine: "make", renderedBeforeCursor: "$ ma"))           // 2 missing
        XCTAssertFalse(rowConfirmsEcho(typedLine: "", renderedBeforeCursor: "$ "))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "   ", renderedBeforeCursor: "$    "))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "LS", renderedBeforeCursor: "$ ls"))             // case-sensitive
        XCTAssertFalse(rowConfirmsEcho(typedLine: "secret", renderedBeforeCursor: ""))
    }

    func testSlackBoundaryThreeVersusFour() {
        // Boundary: 3 typed chars get no slack, 4 typed chars get exactly one.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "pwd", renderedBeforeCursor: "$ pw"))
        XCTAssertTrue(rowConfirmsEcho(typedLine: "pwd", renderedBeforeCursor: "$ pwd"))
        XCTAssertTrue(rowConfirmsEcho(typedLine: "pwdx", renderedBeforeCursor: "$ pwd"))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "pwdxy", renderedBeforeCursor: "$ pwd"))       // 2 missing
    }

    func testSlackCountsTypedLengthAfterTrimming() {
        // "abc " trims to "abc" (3 chars): the trailing space must not buy slack.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "abc ", renderedBeforeCursor: "$ ab"))
    }

    func testEmptyTypedLineNeverConfirmsEvenAgainstEmptyScreen() {
        // An empty suffix trivially "matches" every string; it must still be false.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "", renderedBeforeCursor: ""))
        XCTAssertFalse(rowConfirmsEcho(typedLine: " ", renderedBeforeCursor: " "))
    }

    func testMaskedEchoOfFullLengthSuppressed() {
        // A mask of exactly the typed length, and a one-short mask, both fail.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: "Password: ******"))
        XCTAssertFalse(rowConfirmsEcho(typedLine: "pass", renderedBeforeCursor: "pin: ****"))
    }

    func testPartialEchoSuppressed() {
        // Only the first half of the line is on screen.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: "$ hunt"))
    }

    func testTypedTextNotAtCursorSuppressed() {
        // The typed text appears earlier on screen but not right before the cursor.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: "hunter2 Password: "))
    }

    func testCaseChangeInSlackRegionSuppressed() {
        // With slack, the remaining prefix must still match exactly (case-sensitive).
        XCTAssertFalse(rowConfirmsEcho(typedLine: "Make", renderedBeforeCursor: "$ mak"))
    }

    func testLongerRenderedTailThanTypedSuppressed() {
        // Extra characters after the typed text mean it is not what was echoed last.
        XCTAssertFalse(rowConfirmsEcho(typedLine: "ls", renderedBeforeCursor: "$ lsx"))
    }

    // MARK: - renderedTextBeforeCursor

    func testWrappedLine() {
        let oracle = GridOracle(rows: ["$ aaaaaaaa", "aaaabbbb  "], cursor: EchoCursor(row: 1, col: 8), columns: 10)
        let text = renderedTextBeforeCursor(oracle: oracle, maxChars: 13)
        XCTAssertEqual(text, "$ aaaaaaaaaaaabbbb")
        XCTAssertTrue(rowConfirmsEcho(typedLine: "aaaaaaaaaaaabbbb", renderedBeforeCursor: text!))
    }

    func testUnreadableGridGivesNil() {
        XCTAssertNil(renderedTextBeforeCursor(oracle: GridOracle(rows: [], cursor: nil, columns: 10), maxChars: 5))
        XCTAssertNil(renderedTextBeforeCursor(oracle: GridOracle(rows: ["abc"], cursor: EchoCursor(row: 0, col: 3), columns: nil), maxChars: 5))
    }

    func testReadsCursorRowUpToCursorOnly() {
        // Text at and after the cursor column is not "before the cursor".
        let oracle = GridOracle(rows: ["$ ls junk"], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 4), "$ ls")
    }

    func testBlankCellsReadAsSpaces() {
        let oracle = GridOracle(rows: ["$ a"], cursor: EchoCursor(row: 0, col: 6), columns: 8)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 1), "$ a   ")
    }

    func testMaxCharsBoundaryStopsBeforeEarlierRow() {
        // Cursor row holds 4 chars. maxChars 4: already enough, no earlier row.
        let rows = ["first row ", "$ ls      "]
        let oracle = GridOracle(rows: rows, cursor: EchoCursor(row: 1, col: 4), columns: 10)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 4), "$ ls")
        // maxChars 5: one short, so exactly one earlier whole row is prepended.
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 5), "first row $ ls")
    }

    func testEarlierRowsOldestFirstAndStopAtTop() {
        let rows = ["r0", "r1", "r2"]
        let oracle = GridOracle(rows: rows, cursor: EchoCursor(row: 2, col: 2), columns: 2)
        // Needs more than the whole grid: reads every row, oldest first, no crash at row 0.
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 100), "r0r1r2")
        // Needs 5: cursor row (2) + r1 (4) is still short, so r0 too.
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 5), "r0r1r2")
        // Needs 4: cursor row (2) + r1 (4) suffices.
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 4), "r1r2")
    }

    func testCursorAtColumnZeroReadsEmptyCursorRow() {
        let oracle = GridOracle(rows: ["ab", "  "], cursor: EchoCursor(row: 1, col: 0), columns: 2)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 0), "")
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 1), "ab")
    }

    func testUnreadableCellOnCursorRowGivesNil() {
        var oracle = GridOracle(rows: ["$ ls"], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        oracle.unreadable = [EchoCursor(row: 0, col: 2)]
        XCTAssertNil(renderedTextBeforeCursor(oracle: oracle, maxChars: 4))
    }

    func testUnreadableCellOnNeededEarlierRowGivesNil() {
        var oracle = GridOracle(rows: ["abcd", "$ ls"], cursor: EchoCursor(row: 1, col: 4), columns: 4)
        oracle.unreadable = [EchoCursor(row: 0, col: 3)]
        XCTAssertNil(renderedTextBeforeCursor(oracle: oracle, maxChars: 8))
        // The same bad cell is irrelevant when the earlier row is not needed.
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 4), "$ ls")
    }

    func testCursorBeyondColumnsGivesNil() {
        // A cursor past the row width means the grid view is inconsistent, even
        // when the backing would happily return cells past `columns`.
        let oracle = ScriptedEchoOracle()
        oracle.columns = 3
        oracle.nextCursor = EchoCursor(row: 0, col: 4)
        oracle.cellAt = { _, _ in EchoCell(scalar: "x") }
        XCTAssertNil(renderedTextBeforeCursor(oracle: oracle, maxChars: 1))
        // Control: the same backing with the cursor in range reads normally.
        oracle.nextCursor = EchoCursor(row: 0, col: 3)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 1), "xxx")
    }

    func testCursorAtColumnsBoundaryReadsWholeRow() {
        // Pending-wrap: cursor sits at col == columns after the last cell.
        let oracle = GridOracle(rows: ["abc"], cursor: EchoCursor(row: 0, col: 3), columns: 3)
        XCTAssertEqual(renderedTextBeforeCursor(oracle: oracle, maxChars: 1), "abc")
    }

    func testNegativeCursorOrNonPositiveColumnsGivesNil() {
        XCTAssertNil(renderedTextBeforeCursor(
            oracle: GridOracle(rows: ["abc"], cursor: EchoCursor(row: -1, col: 1), columns: 3), maxChars: 1))
        XCTAssertNil(renderedTextBeforeCursor(
            oracle: GridOracle(rows: ["abc"], cursor: EchoCursor(row: -1, col: 0), columns: 3), maxChars: 0))
        XCTAssertNil(renderedTextBeforeCursor(
            oracle: GridOracle(rows: ["abc"], cursor: EchoCursor(row: 0, col: -1), columns: 3), maxChars: 1))
        XCTAssertNil(renderedTextBeforeCursor(
            oracle: GridOracle(rows: ["abc"], cursor: EchoCursor(row: 0, col: 0), columns: 0), maxChars: 1))
    }

    func testSilentPasswordPromptEndToEnd() {
        // Grid shows the prompt only: the typed password never rendered.
        let oracle = GridOracle(rows: ["Password: "], cursor: EchoCursor(row: 0, col: 10), columns: 20)
        let text = renderedTextBeforeCursor(oracle: oracle, maxChars: 7)
        XCTAssertEqual(text, "Password: ")
        XCTAssertFalse(rowConfirmsEcho(typedLine: "hunter2", renderedBeforeCursor: text ?? ""))
    }
}

/// Scripted grid: `rows` padded/truncated to `columns`. Cells listed in
/// `unreadable` (and any out-of-range read) return nil.
struct GridOracle: EchoOracle {
    var rows: [String]
    var cursorAt: EchoCursor?
    var columns: Int?
    var unreadable: [EchoCursor] = []
    var isAlternateBuffer: Bool = false

    init(rows: [String], cursor: EchoCursor?, columns: Int?) {
        self.rows = rows
        self.cursorAt = cursor
        self.columns = columns
    }

    func cursor() -> EchoCursor? { cursorAt }

    func cell(row: Int, col: Int) -> EchoCell? {
        guard let columns, row >= 0, row < rows.count, col >= 0, col < columns else { return nil }
        if unreadable.contains(EchoCursor(row: row, col: col)) { return nil }
        let scalars = Array(rows[row].unicodeScalars)
        guard col < scalars.count, scalars[col] != " " else { return EchoCell(scalar: nil) }
        return EchoCell(scalar: scalars[col])
    }
}
