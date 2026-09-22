// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// tmux key-name -> the bytes to send after the prefix. Covers every class a
/// `list-keys` binding key can take; nil for anything unencodable (command-mode
/// fallback). Bytes are exact: a wrong byte sends the wrong key to tmux.
final class TmuxKeyEncodingTests: XCTestCase {
    func testPrintableSingleChar() {
        XCTAssertEqual(tmuxKeyBytes("|"), [0x7c])
        XCTAssertEqual(tmuxKeyBytes("-"), [0x2d])
        XCTAssertEqual(tmuxKeyBytes("x"), [0x78])
        XCTAssertEqual(tmuxKeyBytes("%"), [0x25])
    }

    func testCtrlLetter() {
        XCTAssertEqual(tmuxKeyBytes("C-a"), [0x01])
        XCTAssertEqual(tmuxKeyBytes("C-z"), [0x1a])
    }

    func testNamedSpecials() {
        XCTAssertEqual(tmuxKeyBytes("Space"), [0x20])
        XCTAssertEqual(tmuxKeyBytes("Enter"), [0x0d])
        XCTAssertEqual(tmuxKeyBytes("Tab"), [0x09])
        XCTAssertEqual(tmuxKeyBytes("Escape"), [0x1b])
        XCTAssertEqual(tmuxKeyBytes("BSpace"), [0x7f])
    }

    func testMetaPrefixesWithEsc() {
        XCTAssertEqual(tmuxKeyBytes("M-x"), [0x1b, 0x78])
        XCTAssertEqual(tmuxKeyBytes("M-Enter"), [0x1b, 0x0d])
    }

    func testArrows() {
        XCTAssertEqual(tmuxKeyBytes("Up"), [0x1b, 0x5b, 0x41])     // ESC [ A
        XCTAssertEqual(tmuxKeyBytes("Down"), [0x1b, 0x5b, 0x42])
        XCTAssertEqual(tmuxKeyBytes("Right"), [0x1b, 0x5b, 0x43])
        XCTAssertEqual(tmuxKeyBytes("Left"), [0x1b, 0x5b, 0x44])
    }

    func testFunctionKeyF1UsesSS3() {
        XCTAssertEqual(tmuxKeyBytes("F1"), [0x1b, 0x4f, 0x50])     // ESC O P
    }

    func testUnencodableReturnsNil() {
        XCTAssertNil(tmuxKeyBytes(""))
        XCTAssertNil(tmuxKeyBytes("MouseDown1Pane"))
        XCTAssertNil(tmuxKeyBytes("NotAKey"))
    }
}
