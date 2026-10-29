// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Learning a line edited in place. Critical tier (feeds the learned store): the
/// edit buffer must hold exactly what was typed, stop following anything it cannot
/// model, and the screen check must reject any mismatch.
final class LineEditBufferTests: XCTestCase {
    private func typed(_ s: String) -> LineEditBuffer {
        var b = LineEditBuffer()
        for scalar in s.unicodeScalars { b.insert(scalar) }
        return b
    }

    func testTypingAloneIsNotAnEdit() {
        var b = typed("ls -la")
        b.deleteBackward()
        XCTAssertEqual(b.text, "ls -l")
        XCTAssertFalse(b.edited, "typing and backspacing at the end is not an in-place edit")
    }

    func testInsertAtTheCursor() {
        var b = typed("git chekout")
        for _ in 0..<4 { b.moveLeft() }
        b.insert("c")
        XCTAssertEqual(b.text, "git checkout")
        XCTAssertEqual(b.beforeCursor, "git chec")
        XCTAssertEqual(b.afterCursor, "kout")
        XCTAssertTrue(b.edited)
    }

    func testCursorStopsAtBothEnds() {
        var b = typed("ab")
        for _ in 0..<5 { b.moveLeft() }
        b.insert("x")
        XCTAssertEqual(b.text, "xab")
        for _ in 0..<5 { b.moveRight() }
        b.insert("y")
        XCTAssertEqual(b.text, "xaby")
    }

    func testBackspaceAtStartAndDeleteAtEndDoNothing() {
        var b = typed("ab")
        b.moveToStart()
        b.deleteBackward()
        XCTAssertEqual(b.text, "ab")
        b.moveToEnd()
        b.deleteForward()
        XCTAssertEqual(b.text, "ab")
    }

    func testDeleteForwardRemovesTheCharacterUnderTheCursor() {
        var b = typed("lss")
        b.moveLeft()
        b.deleteForward()
        XCTAssertEqual(b.text, "ls")
    }

    func testKillWordBackwardTakesTrailingSpacesThenTheWord() {
        var b = typed("git status  ")
        b.killWordBackward()
        XCTAssertEqual(b.text, "git ")
        b.killWordBackward()
        XCTAssertEqual(b.text, "")
        b.killWordBackward()
        XCTAssertEqual(b.text, "", "nothing left to kill")
    }

    func testKillToStartAndToEndSplitAtTheCursor() {
        var b = typed("abcdef")
        for _ in 0..<2 { b.moveLeft() }
        b.killToEnd()
        XCTAssertEqual(b.text, "abcd")
        b.moveLeft()
        b.killToStart()
        XCTAssertEqual(b.text, "d")
        XCTAssertEqual(b.beforeCursor, "")
    }

    func testClearStartsAFreshLine() {
        var b = typed("x")
        b.moveLeft()
        b.markUnusable()
        b.clear()
        XCTAssertEqual(b, LineEditBuffer())
        XCTAssertTrue(b.usable)
        XCTAssertFalse(b.edited)
    }
}

final class InputTokenTrackerLineEditTests: XCTestCase {
    private let left: [UInt8] = Array("\u{1b}[D".utf8)
    private let right: [UInt8] = Array("\u{1b}[C".utf8)
    private let home: [UInt8] = Array("\u{1b}[H".utf8)
    private let end: [UInt8] = Array("\u{1b}[F".utf8)
    private let up: [UInt8] = Array("\u{1b}[A".utf8)
    private let pasteOn: [UInt8] = Array("\u{1b}[200~".utf8)
    private let pasteOff: [UInt8] = Array("\u{1b}[201~".utf8)
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func repeated(_ seq: [UInt8], _ n: Int) -> [UInt8] { (0..<n).flatMap { _ in seq } }

    func testInsertAfterLeftLearnsTheFinalLine() {
        var t = InputTokenTracker()
        let streamed = t.observe(bytes("git chekout main"))
        XCTAssertEqual(streamed.map(\.token), ["git", "chekout"], "words before the edit stream as typed")
        let resets = t.lineResets
        XCTAssertEqual(t.observe(repeated(left, 9) + bytes("c")), [])
        XCTAssertGreaterThan(t.lineResets, resets, "the App drops the streamed words at the edit")
        XCTAssertEqual(t.observe(bytes("\r")), [
            CommittedToken(token: "git", previous: nil),
            CommittedToken(token: "checkout", previous: "git"),
            CommittedToken(token: "main", previous: "checkout"),
        ])
    }

    func testWordsTypedAfterAnEditAreNotStreamedTwice() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ls"))
        _ = t.observe(left + right)
        XCTAssertEqual(t.observe(bytes(" -la ")), [], "the edited line is emitted once, at Enter")
        XCTAssertEqual(t.observe(bytes("\r")).map(\.token), ["ls", "-la"])
    }

    func testEditedLineExposesBothHalvesOfTheCursor() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("echo helo") + left + bytes("l"))
        XCTAssertEqual(t.editedLine?.beforeCursor, "echo hell")
        XCTAssertEqual(t.editedLine?.afterCursor, "o")
        _ = t.observe(bytes("\r"))
        XCTAssertNil(t.editedLine, "Enter starts a new line")
    }

    func testUneditedLineHasNoEditedLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ls -la"))
        XCTAssertNil(t.editedLine)
    }

    func testApplicationCursorLeftIsAnEditNotText() {
        // `ESC O D` used to leave its `D` in the word.
        var t = InputTokenTracker()
        let committed = t.observe(bytes("ab") + bytes("\u{1b}OD") + bytes("x\r"))
        XCTAssertEqual(committed, [CommittedToken(token: "axb", previous: nil)])
    }

    func testFunctionKeyInSS3FormIsSwallowed() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("ab") + bytes("\u{1b}OP") + bytes("c\r"))
        XCTAssertEqual(committed, [CommittedToken(token: "abc", previous: nil)])
    }

    func testOtherHomeAndEndEncodingsEdit() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("s") + bytes("\u{1b}[7~") + bytes("l") + bytes("\u{1b}[8~") + bytes(" x\r"))
        XCTAssertEqual(committed.map(\.token), ["ls", "x"])
    }

    func testDeleteKeyEditsTheLine() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("lss") + left + bytes("\u{1b}[3~") + bytes("\r"))
        XCTAssertEqual(committed.map(\.token), ["ls"])
    }

    func testCtrlWKeepsTheRestOfTheLine() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git status --short") + [0x17] + bytes("--long\r"))
        XCTAssertEqual(committed, [
            CommittedToken(token: "git", previous: nil),
            CommittedToken(token: "status", previous: "git"),
            CommittedToken(token: "--long", previous: "status"),
        ])
    }

    func testHomeThenLeadingSpaceOptsTheLineOut() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("ls -la") + home + bytes(" ") + bytes("\r"))
        XCTAssertTrue(t.lastCommittedLineOptedOut, "a leading space added by an edit still opts the line out")
        XCTAssertEqual(committed.map(\.token), ["ls", "-la"], "the App drops opted-out tokens; the tracker reports them")
    }

    func testEditedLineStillDropsSecretFlagValues() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("mysql -u root -p hunter2") + home + end + bytes("\r"))
        XCTAssertEqual(committed.map(\.token), ["mysql", "-u", "root", "-p"])
        XCTAssertEqual(t.droppedAsSecret, 1)
    }

    func testHistoryRecallStopsFollowingTheLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git log") + left + up)
        XCTAssertNil(t.editedLine, "a recalled line holds text that was never typed here")
        // As before: only the words typed after the recall are learned.
        XCTAssertEqual(t.observe(bytes(" --oneline\r")), [CommittedToken(token: "--oneline", previous: nil)])
    }

    func testPasteOnAnEditedLineIsNeverLearned() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("echo ") + pasteOn + bytes("s3cret") + pasteOff + left + bytes("\r"))
        XCTAssertEqual(committed, [])
        XCTAssertNil(t.editedLine)
    }

    func testEditBeforeAPasteIsNeverLearnedEither() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("echo x") + left + right + pasteOn + bytes("s3cret") + pasteOff + bytes("\r"))
        XCTAssertFalse(committed.contains { $0.token.contains("s3cret") })
        XCTAssertFalse(committed.contains { $0.token == "echo" }, "the edited line is not re-read once pasted into")
    }

    func testTabStopsFollowingTheLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git co") + left + right + [0x09])
        XCTAssertNil(t.editedLine)
    }

    func testCtrlCDropsTheEditedLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("rm -rf x") + left + [0x03])
        XCTAssertEqual(t.observe(bytes("ls\r")), [CommittedToken(token: "ls", previous: nil)])
    }

    func testCtrlAStopsFollowingBecauseItIsTheTmuxPrefix() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab") + left + [0x01])
        XCTAssertNil(t.editedLine)
    }

    func testModifiedArrowStopsFollowing() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab") + bytes("\u{1b}[1;5D"))
        XCTAssertNil(t.editedLine, "Ctrl-Left moves by word, which the buffer does not model")
    }

    func testMetaKeyStopsFollowing() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab") + bytes("\u{1b}b") + left)
        XCTAssertNil(t.editedLine)
    }

    func testNonAsciiInputStopsFollowing() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab") + left + bytes("é"))
        XCTAssertNil(t.editedLine)
    }

    func testPastedEnterDoesNotLetTheRestOfThePastePassAsTyped() {
        var t = InputTokenTracker()
        _ = t.observe(pasteOn + bytes("x\rhunter2") + pasteOff)
        _ = t.observe(left)
        XCTAssertNil(t.editedLine, "pasted text must never be re-read as typed")
        XCTAssertFalse(t.observe(bytes("\r")).contains { $0.token.contains("hunter") })
    }

    func testPastedCtrlCDoesNotLetTheRestOfThePastePassAsTyped() {
        var t = InputTokenTracker()
        _ = t.observe(pasteOn + bytes("x") + [0x03] + bytes("hunter2") + pasteOff)
        _ = t.observe(left)
        XCTAssertNil(t.editedLine)
        XCTAssertFalse(t.observe(bytes("\r")).contains { $0.token.contains("hunter") })
    }

    func testSpaceInsertedAfterAnEditDoesNotOptTheLineOut() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("gitstatus") + repeated(left, 6) + bytes(" ") + bytes("\r"))
        XCTAssertEqual(committed.map(\.token), ["git", "status"])
        XCTAssertFalse(t.lastCommittedLineOptedOut)
    }

    func testLeadingSpaceTypedFirstStillOptsOutAfterAnEdit() {
        var t = InputTokenTracker()
        _ = t.observe(bytes(" ls") + left + right + bytes("\r"))
        XCTAssertTrue(t.lastCommittedLineOptedOut)
    }

    func testOtherSwallowedKeysStopFollowing() {
        for key in ["\u{1b}[2~", "\u{1b}[Z", "\u{1b}[15~", "\u{1b}[9001~"] {
            var t = InputTokenTracker()
            _ = t.observe(bytes("ab") + left + bytes(key))
            XCTAssertNil(t.editedLine, "key \(key.debugDescription) must stop the buffer")
        }
    }

    func testSecretFlagContextSurvivesALineBreak() {
        // `-p`, a control key that breaks the line, then the value: still dropped.
        var t = InputTokenTracker()
        _ = t.observe(bytes("mysql -p ") + [0x04])
        let committed = t.observe(bytes("hunter2\r"))
        XCTAssertFalse(committed.contains { $0.token == "hunter2" })
        XCTAssertEqual(t.droppedAsSecret, 1)
    }

    func testCtrlCEndsTheSecretFlagContext() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("mysql -p ") + [0x03])
        XCTAssertEqual(t.observe(bytes("hunter2\r")), [CommittedToken(token: "hunter2", previous: nil)],
                       "a new line after Ctrl-C has no flag before it")
    }

    func testWordsBeforeAResetInTheSameChunkAreNotReturned() {
        // The App only drops buffered words at a reset between chunks; within one
        // chunk the tracker must not hand over the words the reset abandoned.
        var t = InputTokenTracker()
        XCTAssertEqual(t.observe(bytes("foo bar ") + up + bytes("ls\r")), [CommittedToken(token: "ls", previous: nil)])
    }

    func testResetClearsTheEdit() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab") + left)
        t.reset()
        XCTAssertNil(t.editedLine)
        XCTAssertEqual(t.observe(bytes("ls\r")), [CommittedToken(token: "ls", previous: nil)])
    }
}

final class EditedLineEchoTests: XCTestCase {
    func testWholeLineOnScreenConfirms() {
        XCTAssertTrue(editedLineConfirmed(typedBefore: "git chec", typedAfter: "kout",
                                          renderedBeforeCursor: "$ git chec", renderedFromCursor: "kout      "))
    }

    func testMismatchBeforeTheCursorFails() {
        XCTAssertFalse(editedLineConfirmed(typedBefore: "git chec", typedAfter: "kout",
                                           renderedBeforeCursor: "$ git che", renderedFromCursor: "ckout     "))
    }

    func testMismatchAfterTheCursorFails() {
        XCTAssertFalse(editedLineConfirmed(typedBefore: "git chec", typedAfter: "kout",
                                           renderedBeforeCursor: "$ git chec", renderedFromCursor: "kuot      "))
    }

    func testMoreOfTheWordOnScreenThanTypedFails() {
        XCTAssertFalse(editedLineConfirmed(typedBefore: "ls", typedAfter: " -l",
                                           renderedBeforeCursor: "$ ls", renderedFromCursor: " -la     "))
    }

    func testCursorAtTheEndNeedsABlankAfterIt() {
        XCTAssertTrue(editedLineConfirmed(typedBefore: "ls -la", typedAfter: "",
                                          renderedBeforeCursor: "$ ls -la", renderedFromCursor: "   "))
        XCTAssertFalse(editedLineConfirmed(typedBefore: "ls -la", typedAfter: "",
                                           renderedBeforeCursor: "$ ls -la", renderedFromCursor: "h  "))
    }

    func testReadEndingRightAfterTheTextConfirms() {
        XCTAssertTrue(editedLineConfirmed(typedBefore: "ab", typedAfter: "cd",
                                          renderedBeforeCursor: "$ ab", renderedFromCursor: "cd"))
    }

    func testNoTextNeverConfirms() {
        XCTAssertFalse(editedLineConfirmed(typedBefore: "  ", typedAfter: "",
                                           renderedBeforeCursor: "$   ", renderedFromCursor: "  "))
        XCTAssertFalse(editedLineConfirmed(typedBefore: "", typedAfter: "",
                                           renderedBeforeCursor: "", renderedFromCursor: ""))
    }

    func testHiddenEchoFails() {
        // A password prompt shows nothing (or a mask), so an edited secret never matches.
        XCTAssertFalse(editedLineConfirmed(typedBefore: "hunt", typedAfter: "er2",
                                           renderedBeforeCursor: "Password: ", renderedFromCursor: "      "))
        XCTAssertFalse(editedLineConfirmed(typedBefore: "hunt", typedAfter: "er2",
                                           renderedBeforeCursor: "Password: ****", renderedFromCursor: "***   "))
    }

    func testReadsFromTheCursorToTheRowEnd() {
        let oracle = GridOracle(rows: ["$ git checkout"], cursor: EchoCursor(row: 0, col: 10), columns: 16)
        XCTAssertEqual(renderedTextFromCursor(oracle: oracle, maxChars: 20), "kout  ")
    }

    func testFollowsAWrappedLine() {
        let oracle = GridOracle(rows: ["$ abcdefgh", "ijk       "], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        XCTAssertEqual(renderedTextFromCursor(oracle: oracle, maxChars: 20), "cdefghijk       ")
    }

    func testDoesNotFollowARowThatDidNotWrap() {
        let oracle = GridOracle(rows: ["$ abc     ", "next row  "], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        XCTAssertEqual(renderedTextFromCursor(oracle: oracle, maxChars: 20), "c     ")
    }

    func testStopsFollowingOnceMaxCharsAreGathered() {
        let oracle = GridOracle(rows: ["$ abcdefgh", "ijkl      "], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        XCTAssertEqual(renderedTextFromCursor(oracle: oracle, maxChars: 6), "cdefgh")
    }

    func testFullLastRowEndsAtTheGrid() {
        let oracle = GridOracle(rows: ["$ abcdefgh"], cursor: EchoCursor(row: 0, col: 4), columns: 10)
        XCTAssertEqual(renderedTextFromCursor(oracle: oracle, maxChars: 20), "cdefgh")
    }

    func testUnreadableGridGivesNil() {
        XCTAssertNil(renderedTextFromCursor(oracle: GridOracle(rows: [], cursor: nil, columns: 10), maxChars: 5))
        XCTAssertNil(renderedTextFromCursor(oracle: GridOracle(rows: ["ab"], cursor: EchoCursor(row: 0, col: 1),
                                                               columns: nil), maxChars: 5))
        XCTAssertNil(renderedTextFromCursor(oracle: GridOracle(rows: ["ab"], cursor: EchoCursor(row: 0, col: 11),
                                                               columns: 10), maxChars: 5))
    }
}
