// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TerminalSettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let s = TerminalSettings()
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertEqual(s.cursorStyle, .block)
        XCTAssertFalse(s.cursorBlink)
        XCTAssertEqual(s.scrollbackLines, 5000)
    }

    func testFontClampBoundaries() {
        XCTAssertEqual(TerminalSettings.clampFont(8), 9)    // min-1 → min
        XCTAssertEqual(TerminalSettings.clampFont(9), 9)    // min
        XCTAssertEqual(TerminalSettings.clampFont(24), 24)  // max
        XCTAssertEqual(TerminalSettings.clampFont(25), 24)  // max+1 → max
        XCTAssertEqual(TerminalSettings.clampFont(13), 13)  // interior
    }

    func testInitClampsFontSize() {
        XCTAssertEqual(TerminalSettings(fontSize: 100).fontSize, 24)
    }

    func testDECSCUSRMap() {
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 0).style, .block)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 0).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 2).style, .block)
        XCTAssertFalse(TerminalSettings.cursorStyle(fromDECSCUSR: 2).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 4).style, .underline)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 5).style, .bar)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 5).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 99).style, .block) // unknown → default
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 1).style, .block)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 1).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 3).style, .underline)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 3).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 6).style, .bar)
        XCTAssertFalse(TerminalSettings.cursorStyle(fromDECSCUSR: 6).blink)
        XCTAssertFalse(TerminalSettings.cursorStyle(fromDECSCUSR: 99).blink)  // unknown → steady
    }

    func testScrollbackPresetsIncludeSpecValues() {
        XCTAssertEqual(TerminalSettings.scrollbackPresets, [1000, 2000, 5000, 10000, Int.max])
    }
}
