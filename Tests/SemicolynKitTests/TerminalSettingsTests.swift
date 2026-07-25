// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TerminalSettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let s = TerminalSettings()
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertEqual(s.cursorStyle, .block)
        XCTAssertFalse(s.cursorBlink)
        XCTAssertEqual(s.scrollbackLines, 5000)
    }

    func testFontClampBoundaries() {
        XCTAssertEqual(TerminalSettings.clampFont(6), 7)    // min-1 → min
        XCTAssertEqual(TerminalSettings.clampFont(7), 7)    // min
        XCTAssertEqual(TerminalSettings.clampFont(24), 24)  // max
        XCTAssertEqual(TerminalSettings.clampFont(25), 24)  // max+1 → max
        XCTAssertEqual(TerminalSettings.clampFont(13), 13)  // interior
    }

    func testInitClampsFontSize() {
        XCTAssertEqual(TerminalSettings(fontSize: 100).fontSize, 24)
    }

    // roundedFont = the persisted/canonical size: clamped AND rounded to a whole pt.
    func testRoundedFontRoundsToNearestInt() {
        XCTAssertEqual(TerminalSettings.roundedFont(8.043364099818564), 8)  // the device value → 8
        XCTAssertEqual(TerminalSettings.roundedFont(12.4), 12)              // rounds down
        XCTAssertEqual(TerminalSettings.roundedFont(12.6), 13)             // rounds up
        XCTAssertEqual(TerminalSettings.roundedFont(13.5), 14)             // .5 rounds away from zero (Swift default)
        XCTAssertEqual(TerminalSettings.roundedFont(13), 13)              // already integer → unchanged
    }

    // Clamp still applies before rounding: out-of-range values land on the integer bound.
    func testRoundedFontClampsThenRounds() {
        XCTAssertEqual(TerminalSettings.roundedFont(6.2), 7)    // below min → clamp to 7
        XCTAssertEqual(TerminalSettings.roundedFont(24.8), 24)  // above max → clamp to 24
    }

    // A fractional value persisted from an earlier pinch normalizes to an int on init AND
    // on decode (the two entry points that store fontSize) — no fractional size survives.
    func testFontSizeIsAlwaysIntegerViaInitAndDecode() throws {
        XCTAssertEqual(TerminalSettings(fontSize: 8.043364099818564).fontSize, 8)
        // Decode a blob carrying a fractional fontSize → normalized to 8 on load.
        let json = #"{"fontSize":8.043364099818564}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSize, 8)
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

    // altScrollMode defaults to .wheel and round-trips through Codable.
    func testAltScrollModeDefaultsToWheel() {
        XCTAssertEqual(TerminalSettings().altScrollMode, .wheel)
    }

    func testAltScrollModeCodableRoundTrip() throws {
        var s = TerminalSettings()
        s.altScrollMode = .pageKeysArrows
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(TerminalSettings.self, from: data)
        XCTAssertEqual(back.altScrollMode, .pageKeysArrows)
    }

    // Old persisted JSON (pre-altScrollMode) must still decode, defaulting the new
    // field, without resetting the other previously-saved fields. This is the
    // anti-regression test: it must FAIL under plain synthesized Codable, because a
    // missing key would throw and (via the store's `try?`) silently wipe settings.
    func testDecodesLegacyJSONWithoutAltScrollMode() throws {
        var s = TerminalSettings()
        s.fontSize = 15
        s.cursorStyle = .bar
        s.cursorBlink = true
        s.scrollbackLines = 2000
        s.altScrollMode = .pageKeysArrows

        let data = try JSONEncoder().encode(s)
        let object = try JSONSerialization.jsonObject(with: data)
        guard var dict = object as? [String: Any] else {
            return XCTFail("expected TerminalSettings to encode as a JSON object")
        }
        XCTAssertNotNil(dict.removeValue(forKey: "altScrollMode"), "fixture must actually contain the key being stripped")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)

        let back = try JSONDecoder().decode(TerminalSettings.self, from: legacyData)
        XCTAssertEqual(back.altScrollMode, .wheel)
        XCTAssertEqual(back.fontSize, 15)
        XCTAssertEqual(back.cursorStyle, .bar)
        XCTAssertTrue(back.cursorBlink)
        XCTAssertEqual(back.scrollbackLines, 2000)
        XCTAssertEqual(back.fontFace, s.fontFace)
    }

    // Migration: a settings blob persisted with a LEGACY altScrollMode ("auto") must decode to
    // .wheel (the new default) AND preserve every other field at its non-default value. The
    // 4-case modes no longer exist; decodeIfPresent on the new 2-case enum would throw on the
    // unknown string, so the migration must swallow it and fall back to .wheel.
    func testLegacyAltScrollModeMigratesToWheel() throws {
        let json = """
        {"fontSize":18,"cursorBlink":true,"scrollbackLines":9000,"altScrollMode":"auto"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(s.altScrollMode, .wheel)            // legacy "auto" -> wheel
        XCTAssertEqual(s.fontSize, 18)                     // other fields preserved
        XCTAssertEqual(s.cursorBlink, true)
        XCTAssertEqual(s.scrollbackLines, 9000)
    }

    // A blob with a VALID new mode round-trips unchanged.
    func testValidAltScrollModePreserved() throws {
        let json = #"{"altScrollMode":"pageKeysArrows"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(s.altScrollMode, .pageKeysArrows)
    }
}
