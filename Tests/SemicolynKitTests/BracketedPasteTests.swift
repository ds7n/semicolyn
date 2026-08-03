// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Bracketed paste wraps clipboard text in ESC[200~ ... ESC[201~ so multi-line pastes stay
/// intact (not auto-executed / not editor-auto-indent-mangled). Raw when the app has it off.
final class BracketedPasteTests: XCTestCase {
    private let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]  // ESC [ 2 0 0 ~
    private let end: [UInt8]   = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]  // ESC [ 2 0 1 ~

    // EP: bracketed=true wraps the UTF-8 payload with the exact markers.
    func testBracketedWraps() {
        let out = SemicolynKit.bracketedPasteBytes("hi", bracketed: true)
        XCTAssertEqual(out, start + Array("hi".utf8) + end)
    }

    // EP: bracketed=false sends raw UTF-8, no markers.
    func testRawNoMarkers() {
        let out = SemicolynKit.bracketedPasteBytes("hi", bracketed: false)
        XCTAssertEqual(out, Array("hi".utf8))
    }

    // BVA: empty string, bracketed -> just the two markers (still valid bracketed paste).
    func testEmptyBracketed() {
        let out = SemicolynKit.bracketedPasteBytes("", bracketed: true)
        XCTAssertEqual(out, start + end)
    }

    // Multi-byte UTF-8 payload is preserved between the markers.
    func testMultiByteUTF8() {
        let out = SemicolynKit.bracketedPasteBytes("é", bracketed: true)
        XCTAssertEqual(out, start + Array("é".utf8) + end)
    }
}
