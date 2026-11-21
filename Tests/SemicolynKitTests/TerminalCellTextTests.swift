// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

/// Cell-text conversions shared by word selection and the echo oracle. SwiftTerm 2 hands
/// cells over as Strings (`TerminalCellSnapshot.text`), where 1.x gave a Character, so
/// the blank forms ("", NUL, space) must all classify the same way.
final class TerminalCellTextTests: XCTestCase {

    // MARK: selectionCharClass

    func testBlankFormsAreSpace() {
        for text in ["", "\u{0}", " ", "\t"] {
            XCTAssertEqual(selectionCharClass(ofCellText: text), .space, text.debugDescription)
        }
    }

    func testEverySelectionPunctuationIsPunct() {
        for ch in selectionPunctuation {
            XCTAssertEqual(selectionCharClass(ofCellText: String(ch)), .punct, String(ch))
        }
    }

    func testWordCells() {
        XCTAssertEqual(selectionCharClass(ofCellText: "a"), .word)
        XCTAssertEqual(selectionCharClass(ofCellText: "Z"), .word)
        XCTAssertEqual(selectionCharClass(ofCellText: "7"), .word)
        XCTAssertEqual(selectionCharClass(ofCellText: "漢"), .word)
        XCTAssertEqual(selectionCharClass(ofCellText: "🙂"), .word)
    }

    func testCombiningSequenceIsOneWordCell() {
        // A base letter plus a combining accent occupies one cell.
        XCTAssertEqual(selectionCharClass(ofCellText: "e\u{301}"), .word)
    }

    func testPunctuationNotInSetIsWord() {
        // "#" and "%" are deliberately absent from selectionPunctuation.
        XCTAssertFalse(selectionPunctuation.contains("#"))
        XCTAssertEqual(selectionCharClass(ofCellText: "#"), .word)
    }

    // MARK: echoCell

    func testEchoBlankFormsAreNil() {
        for text in ["", "\u{0}", " "] {
            XCTAssertNil(echoCell(fromCellText: text).scalar, text.debugDescription)
        }
    }

    func testEchoTabIsNotBlank() {
        // The echo oracle only ever treated NUL and space as blank; keep that exactly.
        XCTAssertEqual(echoCell(fromCellText: "\t").scalar, "\t")
    }

    func testEchoFirstScalar() {
        XCTAssertEqual(echoCell(fromCellText: "x").scalar, "x")
        XCTAssertEqual(echoCell(fromCellText: "e\u{301}").scalar, "e")
        XCTAssertEqual(echoCell(fromCellText: "漢").scalar, "漢")
    }

    // MARK: TerminalInputModes

    func testInputModesResolveInteractionMode() {
        XCTAssertEqual(TerminalInputModes(isAlternateBuffer: false, applicationCursor: false,
                                          mouseReporting: false).interactionMode, .localScroll)
        XCTAssertEqual(TerminalInputModes(isAlternateBuffer: false, applicationCursor: true,
                                          mouseReporting: true).interactionMode, .mouseReporting)
        XCTAssertEqual(TerminalInputModes(isAlternateBuffer: true, applicationCursor: false,
                                          mouseReporting: true).interactionMode, .appOwnsInput)
    }

    func testInputModesUnavailableIsAllOff() {
        XCTAssertEqual(TerminalInputModes.unavailable,
                       TerminalInputModes(isAlternateBuffer: false, applicationCursor: false,
                                          mouseReporting: false))
    }
}
