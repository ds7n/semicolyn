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

    // MARK: sanitizing (security audit H2)

    // Adversarial: an embedded end marker must not close the paste early. The ESC is
    // dropped, so "[201~" stays literal text inside the brackets and the trailing
    // command is never typed outside them.
    func testEmbeddedEndMarkerCannotBreakOut() {
        let out = SemicolynKit.bracketedPasteBytes("ls\u{1b}[201~rm -rf ~\n", bracketed: true)
        XCTAssertEqual(out, start + Array("ls[201~rm -rf ~\n".utf8) + end)
    }

    // Adversarial: an embedded start marker is neutralized the same way.
    func testEmbeddedStartMarkerDropped() {
        let out = SemicolynKit.bracketedPasteBytes("a\u{1b}[200~b", bracketed: true)
        XCTAssertEqual(out, start + Array("a[200~b".utf8) + end)
    }

    // Adversarial: the 8-bit C1 CSI (U+009B) form of the end marker is dropped too.
    func testC1CSIEndMarkerDropped() {
        let out = SemicolynKit.bracketedPasteBytes("a\u{9b}201~b", bracketed: true)
        XCTAssertEqual(out, start + Array("a201~b".utf8) + end)
    }

    // EP: tab, newline and carriage return are the only controls kept.
    func testTabNewlineCarriageReturnKept() {
        let out = SemicolynKit.bracketedPasteBytes("a\tb\nc\rd", bracketed: true)
        XCTAssertEqual(out, start + Array("a\tb\nc\rd".utf8) + end)
    }

    // Adversarial: Ctrl-C, Ctrl-D, the tmux prefix Ctrl-B, BEL and NUL never reach the app.
    func testOtherC0ControlsDropped() {
        let out = SemicolynKit.bracketedPasteBytes("x\u{03}\u{04}\u{02}\u{07}\u{00}y", bracketed: true)
        XCTAssertEqual(out, start + Array("xy".utf8) + end)
    }

    // BVA around the kept controls and the printable range:
    // 0x08 drop, 0x09 keep, 0x0A keep, 0x0B drop, 0x0C drop, 0x0D keep, 0x0E drop,
    // 0x1F drop, 0x20 keep, 0x7E keep, 0x7F drop.
    func testControlBoundaries() {
        let input = "\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{1F}\u{20}\u{7E}\u{7F}"
        let out = SemicolynKit.bracketedPasteBytes(input, bracketed: false)
        XCTAssertEqual(out, [0x09, 0x0A, 0x0D, 0x20, 0x7E])
    }

    // BVA around C1: U+007F..U+009F dropped, U+00A0 (NBSP) kept.
    func testC1Boundaries() {
        let out = SemicolynKit.bracketedPasteBytes("\u{80}\u{9F}\u{A0}", bracketed: false)
        XCTAssertEqual(out, Array("\u{A0}".utf8))
    }

    // EP: an unbracketed paste is sanitized too (an ESC there could drive readline).
    func testRawPasteSanitized() {
        let out = SemicolynKit.bracketedPasteBytes("a\u{1b}[201~b", bracketed: false)
        XCTAssertEqual(out, Array("a[201~b".utf8))
    }

    // EP: emoji and other non-control scalars pass through unchanged.
    func testNonControlScalarsUnchanged() {
        let out = SemicolynKit.bracketedPasteBytes("git commit -m \"✅ ok\"", bracketed: true)
        XCTAssertEqual(out, start + Array("git commit -m \"✅ ok\"".utf8) + end)
    }
}
