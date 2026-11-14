// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Plain keybar text goes through the terminal's own typing path (`typeText`) so the
/// iOS keyboard's view of the line stays in step and a held Backspace keeps repeating
/// (device TF 213: keybar text and accepted suggestions bypassed it, so the repeat
/// stopped early). Anything a modifier changes still goes out as encoded bytes.
final class KeybarTypeTextTests: XCTestCase {
    private final class Spy {
        var sent: [[UInt8]] = []
        var typed: [String] = []
        var accepts = true
    }

    private func make() -> (KeybarInputRouter, Spy) {
        let spy = Spy()
        let r = KeybarInputRouter(applicationCursorKeys: { false },
                                  send: { spy.sent.append($0) },
                                  typeText: { spy.typed.append($0); return spy.accepts })
        return (r, spy)
    }

    func testUnmodifiedSymbolIsTyped() {
        let (r, spy) = make()
        r.tapSymbol("-")
        XCTAssertEqual(spy.typed, ["-"])
        XCTAssertEqual(spy.sent, [])
    }

    func testSymbolFallsBackToBytesWhenNoTerminal() {
        let (r, spy) = make()
        spy.accepts = false
        r.tapSymbol("-")
        XCTAssertEqual(spy.typed, ["-"])
        XCTAssertEqual(spy.sent, [[0x2d]])
    }

    func testArmedCtrlSymbolIsEncodedNotTyped() {
        let (r, spy) = make()
        r.tapCtrl()
        r.tapSymbol("a")
        XCTAssertEqual(spy.typed, [])
        XCTAssertEqual(spy.sent, [[0x01]])
        XCTAssertEqual(r.modifiers.ctrl, .off)   // one-shot consumed
    }

    func testLiteralSecondaryIsTyped() {
        let (r, spy) = make()
        r.emitSecondary(.literal("_"))
        XCTAssertEqual(spy.typed, ["_"])
        XCTAssertEqual(spy.sent, [])
    }

    func testKeySecondaryStaysBytes() {
        let (r, spy) = make()
        r.emitSecondary(.key(.tab, KeyModifiers(shift: true)))
        XCTAssertEqual(spy.typed, [])
        XCTAssertEqual(spy.sent, [encodeKey(.tab, modifiers: KeyModifiers(shift: true), applicationCursorKeys: false)])
    }

    func testNoTypeTextHookSendsBytes() {
        var sent: [[UInt8]] = []
        let r = KeybarInputRouter(applicationCursorKeys: { false }, send: { sent.append($0) })
        r.tapSymbol("-")
        r.emitSecondary(.literal("_"))
        XCTAssertEqual(sent, [[0x2d], [0x5f]])
    }
}
