// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxConfigDecodeTests: XCTestCase {
    private let dec = JSONDecoder()
    private let enc = JSONEncoder()

    func testDecodesNewUseTmuxKey() throws {
        let json = #"{"useTmux": false, "sessionName": "work"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.useTmux, false)
        XCTAssertEqual(c.sessionName, "work")
    }

    func testLegacyAttemptControlModeKeyIsPreserved() throws {
        // Existing saved hosts carry the OLD key; its value must survive.
        let json = #"{"attemptControlMode": true, "sessionName": "x"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.useTmux, true)      // legacy value mapped to the new field
        XCTAssertEqual(c.sessionName, "x")
    }

    func testLegacyFalseIsPreserved() throws {
        let json = #"{"attemptControlMode": false}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.useTmux, false)
    }

    func testNewKeyWinsWhenBothPresent() throws {
        let json = #"{"useTmux": true, "attemptControlMode": false}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.useTmux, true)
    }

    func testAbsentKeyDecodesNil() throws {
        let json = #"{"sessionName": "y"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertNil(c.useTmux)
        XCTAssertEqual(c.sessionName, "y")
    }

    func testEncodeEmitsOnlyUseTmuxNotLegacy() throws {
        let c = TmuxConfig(useTmux: true, sessionName: "z")
        let data = try enc.encode(c)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("useTmux"))
        XCTAssertFalse(s.contains("attemptControlMode"))
    }

    func testRoundTripThroughNewKey() throws {
        let original = TmuxConfig(useTmux: false, sessionName: "rt")
        let back = try dec.decode(TmuxConfig.self, from: enc.encode(original))
        XCTAssertEqual(back, original)
    }

    /// Hosts saved by older builds carry the removed prefix/learning keys. They must still
    /// decode (keeping the real fields) and the dead keys must be dropped on re-save.
    func testRemovedPrefixAndLearningKeysDecodeAndAreDroppedOnEncode() throws {
        let json = #"{"useTmux": true, "sessionName": "w", "prefixOverride": "C-a", "learnedPrefix": "C-a", "learnedActionKeys": {"splitHorizontal": "|"}}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c, TmuxConfig(useTmux: true, sessionName: "w"))
        let s = String(data: try enc.encode(c), encoding: .utf8)!
        XCTAssertFalse(s.contains("prefixOverride"))
        XCTAssertFalse(s.contains("learnedPrefix"))
        XCTAssertFalse(s.contains("learnedActionKeys"))
    }
}
