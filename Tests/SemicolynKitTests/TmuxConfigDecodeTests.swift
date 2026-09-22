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

    func testDecodesPrefixOverride() throws {
        let json = #"{"useTmux": true, "prefixOverride": "C-a"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.prefixOverride, "C-a")
    }

    func testAbsentPrefixOverrideIsNil() throws {
        let json = #"{"useTmux": true}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertNil(c.prefixOverride)
    }

    func testLegacyHostStillDecodesWithNilPrefix() throws {
        // A pre-existing host JSON (attemptControlMode legacy key) must still decode,
        // prefixOverride absent -> nil.
        let json = #"{"attemptControlMode": true, "sessionName": "x"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.useTmux, true)
        XCTAssertNil(c.prefixOverride)
    }

    func testRoundTripPrefixOverride() throws {
        let original = TmuxConfig(useTmux: true, sessionName: "rt", prefixOverride: "C-a")
        let back = try dec.decode(TmuxConfig.self, from: enc.encode(original))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.prefixOverride, "C-a")
    }

    func testEncodeOmitsPrefixOverrideWhenAbsent() throws {
        let c = TmuxConfig(useTmux: true, sessionName: "z")
        let data = try enc.encode(c)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertFalse(s.contains("prefixOverride"))
    }

    // Auto-learned prefix (populated by discovery, distinct from the manual override).
    func testDecodesLearnedPrefix() throws {
        let json = #"{"useTmux": true, "learnedPrefix": "C-a"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.learnedPrefix, "C-a")
    }

    func testAbsentLearnedPrefixIsNil() throws {
        let json = #"{"useTmux": true}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertNil(c.learnedPrefix)
    }

    // Back-compat: a host saved before learnedPrefix existed decodes with it nil.
    func testLegacyHostDecodesWithNilLearnedPrefix() throws {
        let json = #"{"attemptControlMode": true, "sessionName": "x"}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertNil(c.learnedPrefix)
    }

    func testRoundTripLearnedPrefix() throws {
        let original = TmuxConfig(useTmux: true, sessionName: "rt",
                                  prefixOverride: nil, learnedPrefix: "C-a")
        let back = try dec.decode(TmuxConfig.self, from: enc.encode(original))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.learnedPrefix, "C-a")
    }

    func testEncodeOmitsLearnedPrefixWhenAbsent() throws {
        let c = TmuxConfig(useTmux: true, sessionName: "z")
        let data = try enc.encode(c)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertFalse(s.contains("learnedPrefix"))
    }

    // learnedPrefix and prefixOverride are INDEPENDENT fields (setting one leaves the other).
    func testLearnedAndOverrideCoexist() throws {
        let c = TmuxConfig(useTmux: true, sessionName: "s",
                           prefixOverride: "C-b", learnedPrefix: "C-a")
        let back = try dec.decode(TmuxConfig.self, from: enc.encode(c))
        XCTAssertEqual(back.prefixOverride, "C-b")
        XCTAssertEqual(back.learnedPrefix, "C-a")
    }

    func testDecodesLearnedActionKeys() throws {
        let json = #"{"useTmux": true, "learnedActionKeys": {"splitHorizontal": "|", "zoom": "z"}}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertEqual(c.learnedActionKeys?["splitHorizontal"], "|")
        XCTAssertEqual(c.learnedActionKeys?["zoom"], "z")
    }

    func testLegacyHostDecodesWithNilActionKeys() throws {
        let json = #"{"attemptControlMode": true}"#.data(using: .utf8)!
        let c = try dec.decode(TmuxConfig.self, from: json)
        XCTAssertNil(c.learnedActionKeys)
    }

    func testRoundTripLearnedActionKeys() throws {
        let original = TmuxConfig(useTmux: true, sessionName: "s",
                                  prefixOverride: nil, learnedPrefix: "C-a",
                                  learnedActionKeys: ["splitVertical": "-"])
        let back = try dec.decode(TmuxConfig.self, from: enc.encode(original))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.learnedActionKeys?["splitVertical"], "-")
    }

    func testEncodeOmitsActionKeysWhenAbsent() throws {
        let c = TmuxConfig(useTmux: true, sessionName: "z")
        let s = String(data: try enc.encode(c), encoding: .utf8)!
        XCTAssertFalse(s.contains("learnedActionKeys"))
    }
}
