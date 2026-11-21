// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import UIKit
import SwiftTerm

/// The vendored SwiftTerm's held-Backspace fix (Vendor/SwiftTerm/SEMICOLYN.md): the
/// text-input document always starts with a two-space placeholder that no edit removes,
/// so the soft keyboard keeps repeating Backspace after remote-inserted text. Driven
/// through the public UITextInput surface the keyboard itself uses, asserting the bytes
/// SwiftTerm sends and the document the keyboard sees.
final class DeleteRepeatPlaceholderTests: XCTestCase {
    private let del: UInt8 = 0x7f

    // MARK: fresh document

    @MainActor
    func testFreshDocumentIsPlaceholderWithCaretAfterIt() {
        let t = Harness()
        XCTAssertTrue(t.view.hasText)
        XCTAssertEqual(t.documentText, "  ")
        XCTAssertEqual(t.caretOffset, 2)
    }

    // MARK: the bug: Backspace with no locally typed text

    @MainActor
    func testBackspaceAtEmptyPromptSendsDelAndKeepsDocument() {
        let t = Harness()
        for press in 1...3 {
            t.view.deleteBackward()
            XCTAssertTrue(t.view.hasText, "press \(press)")
            XCTAssertEqual(t.documentText, "  ", "press \(press)")
            XCTAssertEqual(t.caretOffset, 2, "press \(press)")
        }
        XCTAssertEqual(t.sentBytes(), [del, del, del])
    }

    // MARK: typed text, boundary at the placeholder

    @MainActor
    func testBackspaceDeletesTypedTextThenKeepsRepeatingAtPlaceholder() {
        let t = Harness()
        t.view.insertText("ab")
        XCTAssertEqual(t.documentText, "  ab")
        t.view.deleteBackward()   // removes "b"
        XCTAssertEqual(t.documentText, "  a")
        t.view.deleteBackward()   // removes "a": the last typed character (boundary)
        XCTAssertEqual(t.documentText, "  ")
        XCTAssertEqual(t.caretOffset, 2)
        t.view.deleteBackward()   // one past the boundary: the placeholder stays
        XCTAssertEqual(t.documentText, "  ")
        XCTAssertTrue(t.view.hasText)
        XCTAssertEqual(t.sentBytes(), Array("ab".utf8) + [del, del, del])
    }

    @MainActor
    func testReturnResetsToPlaceholder() {
        let t = Harness()
        t.view.insertText("ls")
        t.view.insertText("\n")
        XCTAssertEqual(t.documentText, "  ")
        XCTAssertEqual(t.caretOffset, 2)
        XCTAssertEqual(t.sentBytes(), Array("ls".utf8) + [13])
    }

    // MARK: ranges reaching into the placeholder

    @MainActor
    func testCaretCannotMoveIntoPlaceholder() {
        let t = Harness()
        t.select(0, 0)
        XCTAssertEqual(t.caretOffset, 2)
        t.select(1, 1)
        XCTAssertEqual(t.caretOffset, 2)
    }

    @MainActor
    func testChunkSelectionStartingInPlaceholderDeletesOnlyTypedText() {
        let t = Harness()
        t.view.insertText("ab")
        _ = t.sentBytes()
        // Accelerated repeat deletes a selected chunk; a chunk reaching into the
        // placeholder is trimmed to the typed text.
        t.select(0, 4)
        let sel = t.view.selectedTextRange!
        XCTAssertEqual(t.view.offset(from: t.view.beginningOfDocument, to: sel.start), 2)
        XCTAssertEqual(t.view.offset(from: t.view.beginningOfDocument, to: sel.end), 4)
        t.view.deleteBackward()
        XCTAssertEqual(t.documentText, "  ")
        XCTAssertEqual(t.caretOffset, 2)
        XCTAssertEqual(t.sentBytes(), [del, del])
    }

    @MainActor
    func testReplaceOverPlaceholderSendsNoDelForIt() {
        let t = Harness()
        let start = t.view.beginningOfDocument
        let end = t.view.position(from: start, offset: 2)!
        t.view.replace(t.view.textRange(from: start, to: end)!, withText: "x")
        XCTAssertEqual(t.documentText, "  x")
        XCTAssertEqual(t.sentBytes(), Array("x".utf8))
    }
}

/// A terminal view plus a delegate that records what it sends to the remote side.
@MainActor
private final class Harness {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    private let sink = SentBytes()

    init() { view.terminalDelegate = sink }

    var documentText: String {
        guard let all = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) else { return "<nil>" }
        return view.text(in: all) ?? "<nil>"
    }

    var caretOffset: Int {
        guard let sel = view.selectedTextRange else { return -1 }
        return view.offset(from: view.beginningOfDocument, to: sel.start)
    }

    func select(_ from: Int, _ to: Int) {
        let start = view.position(from: view.beginningOfDocument, offset: from)!
        let end = view.position(from: view.beginningOfDocument, offset: to)!
        view.selectedTextRange = view.textRange(from: start, to: end)
    }

    /// The bytes sent since the last call. SwiftTerm hands them to the delegate on a
    /// later main-queue turn, so let the run loop deliver them first.
    func sentBytes() -> [UInt8] {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { sink.bytes.removeAll() }
        return sink.bytes
    }
}

private final class SentBytes: TerminalViewDelegate {
    var bytes: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
