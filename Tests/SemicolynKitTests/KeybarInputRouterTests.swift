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

    // MARK: keyboardInput — armed keybar modifiers applied to chars typed on the
    // SwiftTerm/iOS keyboard (device bug: armed Ctrl then typing 'a' sent plain 'a').

    func testKeyboardInputAppliesArmedCtrlToSingleChar() {
        let (r, spy) = make()
        r.tapCtrl()
        r.keyboardInput([0x61])                          // user types 'a' on the keyboard
        XCTAssertEqual(spy.sent, [[0x01]], "armed Ctrl must turn 'a' into 0x01")
    }

    func testKeyboardInputConsumesArmAfterOneChar() {
        let (r, spy) = make()
        r.tapCtrl()
        r.keyboardInput([0x61])                          // Ctrl+A → 0x01
        r.keyboardInput([0x62])                          // next char plain 'b'
        XCTAssertEqual(spy.sent, [[0x01], [0x62]], "one-shot Ctrl clears after one keyboard char")
    }

    func testKeyboardInputPassesThroughWhenNoModifierArmed() {
        let (r, spy) = make()
        r.keyboardInput([0x61])                          // no modifier → raw
        XCTAssertEqual(spy.sent, [[0x61]])
    }

    func testKeyboardInputPassesMultiByteSequenceUntouchedEvenWhenArmed() {
        let (r, spy) = make()
        r.tapCtrl()
        // An escape sequence (e.g. an arrow already encoded by SwiftTerm) must NOT be
        // re-encoded; it passes through and does NOT consume the arm.
        r.keyboardInput([0x1b, 0x5b, 0x41])              // ESC [ A
        XCTAssertEqual(spy.sent, [[0x1b, 0x5b, 0x41]])
        // Arm still active for the next single char.
        r.keyboardInput([0x61])
        XCTAssertEqual(spy.sent.last, [0x01], "arm survived the multi-byte passthrough")
    }

    func testArmedCtrlAppliesToNextSymbolThenClears() {
        let (r, spy) = make()
        r.tapCtrl()
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03]])              // Ctrl+C
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03], [0x63]])      // second is plain 'c' (one-shot cleared)
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
