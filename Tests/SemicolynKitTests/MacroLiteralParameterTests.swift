// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// D-11: macros have no parameters. `${...}` is plain text in a template, and a
/// macro stored by an older build with a `parameterizedBody` decodes and sends
/// exactly the text the user typed, `${...}` included.
final class MacroLiteralParameterTests: XCTestCase {
    private func chars(_ s: String) -> [MacroEvent] { s.map { MacroEvent(key: .char($0)) } }

    // MARK: - Template parsing

    func testDollarBraceIsLiteralText() throws {
        XCTAssertEqual(try MacroTemplate.parse("echo ${HOME}"), chars("echo ${HOME}"))
    }

    func testDollarBraceWithDefaultSyntaxIsLiteral() throws {
        XCTAssertEqual(try MacroTemplate.parse("${ns:prod}"), chars("${ns:prod}"))
    }

    func testEmptyDollarBraceIsLiteral() throws {
        XCTAssertEqual(try MacroTemplate.parse("${}"), chars("${}"))
    }

    func testDollarBraceWithInvalidNameIsLiteral() throws {
        // Previously an "Invalid parameter name" class; now just text.
        XCTAssertEqual(try MacroTemplate.parse("${a b}"), chars("${a b}"))
    }

    func testUnclosedDollarBraceRunsToEndAsLiteral() throws {
        XCTAssertEqual(try MacroTemplate.parse("echo ${HOME"), chars("echo ${HOME"))
    }

    func testDollarBraceThenKeyPlaceholderStillParsesTheKey() throws {
        XCTAssertEqual(try MacroTemplate.parse("cd ${DIR}{Enter}"),
                       chars("cd ${DIR}") + [MacroEvent(key: .enter)])
    }

    func testLoneDollarAndKeyPlaceholderUnchanged() throws {
        // A `$` not followed by `{` is a plain char, and `{Ctrl+R}` is still a chord.
        XCTAssertEqual(try MacroTemplate.parse("$x{Ctrl+R}"),
                       chars("$x") + [MacroEvent(key: .char("R"), modifiers: KeyModifiers(control: true))])
    }

    func testBareBraceErrorsUnchanged() {
        // Only `${` became literal: a bare `{name}` is still a key placeholder.
        XCTAssertThrowsError(try MacroTemplate.parse("{HOME}")) {
            XCTAssertEqual($0 as? MacroTemplateError, .unknownKey("HOME"))
        }
    }

    // MARK: - Legacy stored records

    /// A macro saved by a build that supported parameters: `body` holds only the
    /// literal keystrokes, `parameterizedBody` interleaves `${ns:prod}` and `${pod}`.
    private let legacyParameterized = Data("""
    {"id":{"raw":"m-legacy"},"name":"kexec",
     "body":[
       {"key":{"kind":"char","value":"k"},"modifiers":{"control":false,"option":false,"shift":false}},
       {"key":{"kind":"char","value":" "},"modifiers":{"control":false,"option":false,"shift":false}},
       {"key":{"kind":"enter"},"modifiers":{"control":false,"option":false,"shift":false}}
     ],
     "parameterizedBody":[
       {"kind":"event","event":{"key":{"kind":"char","value":"k"},"modifiers":{"control":false,"option":false,"shift":false}}},
       {"kind":"event","event":{"key":{"kind":"char","value":" "},"modifiers":{"control":false,"option":false,"shift":false}}},
       {"kind":"placeholder","placeholder":{"name":"ns","defaultValue":"prod"}},
       {"kind":"placeholder","placeholder":{"name":"pod"}},
       {"kind":"event","event":{"key":{"kind":"enter"},"modifiers":{"control":false,"option":false,"shift":false}}}
     ]}
    """.utf8)

    func testLegacyParameterizedMacroDecodesToTypedText() throws {
        let m = try JSONDecoder().decode(Macro.self, from: legacyParameterized)
        XCTAssertEqual(m.id, MacroID("m-legacy"))
        XCTAssertEqual(m.name, "kexec")
        XCTAssertEqual(m.body, chars("k ${ns:prod}${pod}") + [MacroEvent(key: .enter)])
    }

    func testLegacyParameterizedMacroSendsExactTypedBytes() throws {
        let m = try JSONDecoder().decode(Macro.self, from: legacyParameterized)
        XCTAssertEqual(m.encoded(applicationCursorKeys: false), Array("k ${ns:prod}${pod}\r".utf8))
    }

    func testLegacyEmptyDefaultKeepsTheColon() throws {
        let json = Data("""
        {"id":{"raw":"e"},"name":"e","body":[],
         "parameterizedBody":[{"kind":"placeholder","placeholder":{"name":"x","defaultValue":""}}]}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Macro.self, from: json).body, chars("${x:}"))
    }

    func testReencodedLegacyMacroDropsParameterizedKeyAndKeepsText() throws {
        let m = try JSONDecoder().decode(Macro.self, from: legacyParameterized)
        let data = try JSONEncoder().encode(m)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "name", "body"])
        XCTAssertEqual(try JSONDecoder().decode(Macro.self, from: data), m)
    }

    func testPlainMacroWithoutParameterizedKeyDecodes() throws {
        let legacy = Data("""
        {"id":{"raw":"old"},"name":"deploy",
         "body":[{"key":{"kind":"char","value":"a"},
                  "modifiers":{"control":false,"option":false,"shift":false}}]}
        """.utf8)
        let m = try JSONDecoder().decode(Macro.self, from: legacy)
        XCTAssertEqual(m, Macro(id: MacroID("old"), name: "deploy", body: chars("a")))
    }

    func testUnknownLegacyElementKindFailsToDecode() {
        let json = Data("""
        {"id":{"raw":"x"},"name":"x","body":[],"parameterizedBody":[{"kind":"sorcery"}]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Macro.self, from: json)) { error in
            guard case DecodingError.dataCorrupted(let ctx) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(ctx.debugDescription.contains("sorcery"))
        }
    }
}
