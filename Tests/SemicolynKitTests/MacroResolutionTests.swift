// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `resolveMacroBody` — fills `${…}` placeholders at fire-time. Resolution order for
/// a user placeholder is remembered-for-host → default → prompt; connection
/// placeholders (`${host}`/`${user}`/`${port}`) auto-fill from the live session.
/// Returns `.resolved([MacroEvent])` when every placeholder is filled, else
/// `.needsInput` with the placeholders still requiring a prompt (in order, deduped).
/// Plus the per-host remembered-value store model. (keybar-customization spec
/// "Optional placeholders".)
final class MacroResolutionTests: XCTestCase {
    private func ph(_ n: String, _ d: String? = nil) -> MacroBodyElement {
        .placeholder(MacroPlaceholder(name: n, defaultValue: d))
    }
    private func ev(_ c: Character) -> MacroBodyElement { .event(MacroEvent(key: .char(c))) }
    private func chars(_ s: String) -> [MacroEvent] { s.map { MacroEvent(key: .char($0)) } }

    // MARK: - Connection placeholders auto-fill

    func testConnectionHostAutoFills() {
        let r = resolveMacroBody([ph("host")],
                                 connection: MacroConnectionContext(host: "orchard"),
                                 remembered: [:])
        XCTAssertEqual(r, .resolved(chars("orchard")))
    }

    func testConnectionPlaceholderMissingFromContextNeedsInput() {
        // `${host}` but not connected → prompt rather than send empty.
        let r = resolveMacroBody([ph("host")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .needsInput([MacroPlaceholder(name: "host")]))
    }

    // MARK: - User placeholders: remembered → default → prompt

    func testRememberedValueWinsOverDefault() {
        let r = resolveMacroBody([ph("ns", "default-ns")],
                                 connection: MacroConnectionContext(),
                                 remembered: ["ns": "prod"])
        XCTAssertEqual(r, .resolved(chars("prod")))
    }

    func testFallsBackToDefaultWhenNotRemembered() {
        let r = resolveMacroBody([ph("ns", "default-ns")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .resolved(chars("default-ns")))
    }

    func testNeedsInputWhenNoRememberedAndNoDefault() {
        let r = resolveMacroBody([ph("ns")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .needsInput([MacroPlaceholder(name: "ns")]))
    }

    func testEmptyDefaultResolvesToEmptyValue() {
        // `${x:}` is an explicit empty value, NOT a prompt — contributes no chars.
        let r = resolveMacroBody([ev("a"), ph("x", ""), ev("b")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .resolved(chars("ab")))
    }

    // MARK: - Interleaving + ordering

    func testEventsAndResolvedPlaceholderInterleaveInOrder() {
        let r = resolveMacroBody([ev("c"), ev("d"), ev(" "), ph("dir", "/tmp")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .resolved(chars("cd /tmp")))
    }

    func testNeedsInputCollectsInOrderAndDedupesByName() {
        // ${a} (twice) and ${b}, none resolvable → one prompt each, a before b.
        let r = resolveMacroBody([ph("a"), ev("x"), ph("b"), ph("a")],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .needsInput([MacroPlaceholder(name: "a"), MacroPlaceholder(name: "b")]))
    }

    func testNoPlaceholdersResolvesToEventsUnchanged() {
        let r = resolveMacroBody([ev("l"), ev("s"), .event(MacroEvent(key: .enter))],
                                 connection: MacroConnectionContext(),
                                 remembered: [:])
        XCTAssertEqual(r, .resolved([MacroEvent(key: .char("l")),
                                     MacroEvent(key: .char("s")),
                                     MacroEvent(key: .enter)]))
    }

    // MARK: - Reserved connection names

    func testReservedConnectionNames() {
        XCTAssertEqual(MacroConnectionContext.reservedNames, ["host", "user", "port"])
        // a non-reserved name is treated as a user placeholder, not a connection one
        let r = resolveMacroBody([ph("hostx")],
                                 connection: MacroConnectionContext(host: "orchard"),
                                 remembered: [:])
        XCTAssertEqual(r, .needsInput([MacroPlaceholder(name: "hostx")]))
    }

    // MARK: - Per-host remembered-value store model

    func testRememberThenLookupForSameHost() {
        var rv = MacroRememberedValues()
        rv.remember("prod", name: "ns", hostID: "h1")
        XCTAssertEqual(rv.values(forHost: "h1"), ["ns": "prod"])
    }

    func testRememberedValuesAreIsolatedPerHost() {
        var rv = MacroRememberedValues()
        rv.remember("prod", name: "ns", hostID: "h1")
        XCTAssertEqual(rv.values(forHost: "h2"), [:])
    }

    func testRememberOverwritesPreviousValueForName() {
        var rv = MacroRememberedValues()
        rv.remember("prod", name: "ns", hostID: "h1")
        rv.remember("stage", name: "ns", hostID: "h1")
        XCTAssertEqual(rv.values(forHost: "h1"), ["ns": "stage"])
    }

    func testRememberedValuesCodableRoundTrip() throws {
        var rv = MacroRememberedValues()
        rv.remember("prod", name: "ns", hostID: "h1")
        rv.remember("8080", name: "port_override", hostID: "h2")
        let data = try JSONEncoder().encode(rv)
        let back = try JSONDecoder().decode(MacroRememberedValues.self, from: data)
        XCTAssertEqual(back, rv)
        XCTAssertEqual(back.values(forHost: "h1"), ["ns": "prod"])
    }
}
