// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarInputRouterTests: XCTestCase {
    /// Captures bytes the router emits.
    private final class Spy {
        var sent: [[UInt8]] = []
        func send(_ b: [UInt8]) { sent.append(b) }
    }

    private func make(app: Bool = false) -> (KeybarInputRouter, Spy) {
        let spy = Spy()
        let router = KeybarInputRouter(applicationCursorKeys: { app }, send: spy.send)
        return (router, spy)
    }

    func testArmedCtrlAppliesToNextSymbolThenClears() {
        let (r, spy) = make()
        r.tapCtrl()
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03]])              // Ctrl+C
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03], [0x63]])      // second is plain 'c' (one-shot cleared)
    }

    func testLockedCtrlAppliesToMultipleKeystrokes() {
        let (r, spy) = make()
        r.doubleTapCtrl()
        r.tapSymbol("x"); r.tapSymbol("s")
        XCTAssertEqual(spy.sent, [[0x18], [0x13]])      // Ctrl+X, Ctrl+S — lock persists
    }

    func testAltSymbolEmitsMetaEscapeOnce() {
        let (r, spy) = make()
        r.armAlt()
        r.tapSymbol("x")
        XCTAssertEqual(spy.sent, [[0x1b, 0x78]])        // Alt+x
        r.tapSymbol("x")
        XCTAssertEqual(spy.sent.last, [0x78])           // plain after consume
    }

    func testEscTabAndArrowsEmitExpectedBytes() {
        let (r, spy) = make()
        r.tapEscape(); r.tapTab(); r.arrow(.up)
        XCTAssertEqual(spy.sent, [[0x1b], [0x09], Array("\u{1b}[A".utf8)])
    }

    func testArrowRespectsApplicationCursorKeys() {
        let (r, spy) = make(app: true)
        r.arrow(.left)
        XCTAssertEqual(spy.sent, [Array("\u{1b}OD".utf8)])
    }

    func testModifierGestureDoesNotSendUntilAKeyFires() {
        let (r, spy) = make()
        r.tapCtrl()
        XCTAssertTrue(spy.sent.isEmpty)                  // arming alone sends nothing
        XCTAssertEqual(r.modifiers.ctrl, .armed)
    }

    func testOnModifierChangeFiresOnArmAndOnKeyConsume() {
        let (r, _) = make()
        var changes = 0
        r.onModifierChange = { changes += 1 }
        r.tapCtrl()              // modifier armed → notify
        XCTAssertEqual(changes, 1)
        r.tapSymbol("c")         // fire() consumes the armed ctrl → notify
        XCTAssertEqual(changes, 2)
    }

    func testTapFKeyEmitsSequence() {
        let (r, spy) = make()
        r.tapFKey(5)
        XCTAssertEqual(spy.sent, [Array("\u{1b}[15~".utf8)])
    }

    // MARK: - Macro firing (4d-2)

    func testFireMacroSendsExpandedBodyAsOneWrite() {
        let (r, spy) = make()
        r.fireMacro([MacroEvent(key: .char("g")), MacroEvent(key: .char("s")),
                     MacroEvent(key: .enter)])
        XCTAssertEqual(spy.sent, [Array("gs".utf8) + [0x0d]])  // one coalesced write
    }

    func testFireMacroRespectsApplicationCursorKeys() {
        let (r, spy) = make(app: true)
        r.fireMacro([MacroEvent(key: .arrow(.down))])
        XCTAssertEqual(spy.sent, [Array("\u{1b}OB".utf8)])
    }

    func testFireMacroIsSelfContainedAndPreservesArmedModifier() {
        // A macro carries its own modifiers; firing it must neither apply nor
        // consume the globally-armed modifier state.
        let (r, spy) = make()
        r.tapCtrl()                                   // arm Ctrl
        r.fireMacro([MacroEvent(key: .char("a"))])
        XCTAssertEqual(spy.sent, [[0x61]])            // plain 'a', NOT Ctrl-A (0x01)
        XCTAssertEqual(r.modifiers.ctrl, .armed)      // still armed for the next real key
    }
}
