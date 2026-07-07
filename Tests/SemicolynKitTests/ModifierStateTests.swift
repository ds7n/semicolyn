// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ModifierStateTests: XCTestCase {
    func testTapArmsCtrlOneShotThenClearsOnConsume() {
        var m = ModifierState()
        m.tapCtrl()
        XCTAssertEqual(m.ctrl, .armed)
        XCTAssertEqual(m.current(), KeyModifiers(control: true))
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.ctrl, .off)               // one-shot cleared
        XCTAssertEqual(m.current(), KeyModifiers())
    }

    func testTapWhileArmedTogglesOff() {
        var m = ModifierState()
        m.tapCtrl(); m.tapCtrl()
        XCTAssertEqual(m.ctrl, .off)
    }

    func testAltAndShiftAreOneShotNoLock() {
        var m = ModifierState()
        m.armAlt()
        XCTAssertEqual(m.current(), KeyModifiers(option: true))
        m.consumeAfterKeystroke()
        XCTAssertFalse(m.current().option)         // cleared
        m.armShift()
        XCTAssertEqual(m.current(), KeyModifiers(shift: true))
        m.consumeAfterKeystroke()
        XCTAssertFalse(m.current().shift)
    }

    func testCombinedCtrlPlusAltBothOneShotClearOnConsume() {
        var m = ModifierState()
        m.tapCtrl(); m.armAlt()
        XCTAssertEqual(m.current(), KeyModifiers(control: true, option: true))
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.current(), KeyModifiers())  // both one-shot: cleared together
    }
}
