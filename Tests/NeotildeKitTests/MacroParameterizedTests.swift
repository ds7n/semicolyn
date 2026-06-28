// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// `Macro`'s optional parameterized body (4d-2): the `${…}` template that resolves at
/// fire-time, persisted as an optional key so older plain-macro records still decode.
/// Covers the element Codable, the derived static `body`, `resolvableBody`, the macro
/// round-trip, and the legacy (no-key) back-compat decode.
final class MacroParameterizedTests: XCTestCase {

    // MARK: - MacroBodyElement Codable

    func testBodyElementCodableRoundTripEvent() throws {
        let el = MacroBodyElement.event(MacroEvent(key: .char("k"),
                                                   modifiers: KeyModifiers(control: true)))
        let back = try JSONDecoder().decode(MacroBodyElement.self,
                                            from: try JSONEncoder().encode(el))
        XCTAssertEqual(back, el)
    }

    func testBodyElementCodableRoundTripPlaceholder() throws {
        let el = MacroBodyElement.placeholder(MacroPlaceholder(name: "ns", defaultValue: "prod"))
        let back = try JSONDecoder().decode(MacroBodyElement.self,
                                            from: try JSONEncoder().encode(el))
        XCTAssertEqual(back, el)
    }

    func testBodyElementDecodeUnknownKindThrows() {
        let json = Data(#"{"kind":"sorcery"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacroBodyElement.self, from: json))
    }

    // MARK: - Parameterized macro shape

    func testParameterizedInitDerivesStaticBodyAndFlag() {
        let tmpl: [MacroBodyElement] = [
            .event(MacroEvent(key: .char("k"))),
            .placeholder(MacroPlaceholder(name: "ns", defaultValue: "prod")),
            .event(MacroEvent(key: .enter)),
        ]
        let m = Macro(id: MacroID("m1"), name: "kctx", parameterizedBody: tmpl)
        XCTAssertTrue(m.isParameterized)
        // body keeps only the literal keystrokes (the placeholder drops out)
        XCTAssertEqual(m.body, [MacroEvent(key: .char("k")), MacroEvent(key: .enter)])
        XCTAssertEqual(m.parameterizedBody, tmpl)
        XCTAssertEqual(m.resolvableBody, tmpl)
    }

    func testPlainMacroIsNotParameterizedAndWrapsBody() {
        let m = Macro(id: MacroID("m2"), name: "ls",
                      body: [MacroEvent(key: .char("l")), MacroEvent(key: .char("s"))])
        XCTAssertFalse(m.isParameterized)
        XCTAssertNil(m.parameterizedBody)
        XCTAssertEqual(m.resolvableBody,
                       [.event(MacroEvent(key: .char("l"))), .event(MacroEvent(key: .char("s")))])
    }

    // MARK: - Codable round-trip + legacy back-compat

    func testParameterizedMacroCodableRoundTrip() throws {
        let tmpl: [MacroBodyElement] = [
            .event(MacroEvent(key: .char("c"))),
            .placeholder(MacroPlaceholder(name: "dir")),
        ]
        let m = Macro(id: MacroID("m3"), name: "cd", parameterizedBody: tmpl)
        let back = try JSONDecoder().decode(Macro.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.parameterizedBody, tmpl)
    }

    func testLegacyMacroWithoutParameterizedKeyDecodesAsPlain() throws {
        // A record from before 4d-2: no `parameterizedBody` key at all.
        let legacy = Data("""
        {"id":{"raw":"old"},"name":"deploy",
         "body":[{"key":{"kind":"char","value":"a"},
                  "modifiers":{"control":false,"option":false,"shift":false}}]}
        """.utf8)
        let m = try JSONDecoder().decode(Macro.self, from: legacy)
        XCTAssertEqual(m.id, MacroID("old"))
        XCTAssertEqual(m.name, "deploy")
        XCTAssertEqual(m.body, [MacroEvent(key: .char("a"))])
        XCTAssertNil(m.parameterizedBody)
        XCTAssertFalse(m.isParameterized)
    }
}
