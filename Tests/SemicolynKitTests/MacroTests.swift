// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Macro data model: `KeyInput`/`KeyModifiers`/`MacroEvent`/`Macro` Codable
/// round-trips and the stable, forward-safe wire schema (4d-2 macros).
final class MacroTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - KeyInput Codable (one representative per case + every arrow dir)

    func testKeyInputCharRoundTrips() throws {
        XCTAssertEqual(try roundTrip(KeyInput.char("k")), .char("k"))
    }

    func testKeyInputSpecialKeysRoundTrip() throws {
        for key in [KeyInput.escape, .tab, .enter, .backspace] {
            XCTAssertEqual(try roundTrip(key), key)
        }
    }

    func testKeyInputArrowsRoundTrip() throws {
        for dir in [ArrowDirection.up, .down, .left, .right] {
            XCTAssertEqual(try roundTrip(KeyInput.arrow(dir)), .arrow(dir))
        }
    }

    func testKeyInputFunctionRoundTrips() throws {
        XCTAssertEqual(try roundTrip(KeyInput.function(7)), .function(7))
    }

    func testKeyInputWireFormIsDiscriminated() throws {
        // Stable schema: kind discriminator + value for payload-carrying cases.
        let charJSON = String(decoding: try JSONEncoder().encode(KeyInput.char("/")), as: UTF8.self)
        XCTAssertTrue(charJSON.contains("\"kind\""), "expected a kind discriminator, got \(charJSON)")
        XCTAssertTrue(charJSON.contains("char"))
        XCTAssertTrue(charJSON.contains("/"))
    }

    func testKeyInputDecodeRejectsUnknownKind() {
        let bogus = Data(#"{"kind":"telekinesis"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeyInput.self, from: bogus)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted for unknown kind, got \(error)")
            }
        }
    }

    // MARK: - KeyModifiers Codable

    func testKeyModifiersRoundTrips() throws {
        let mods = KeyModifiers(control: true, option: false, shift: true)
        XCTAssertEqual(try roundTrip(mods), mods)
    }

    // MARK: - MacroEvent

    func testMacroEventDefaultModifiersAreEmpty() {
        let event = MacroEvent(key: .enter)
        XCTAssertEqual(event.modifiers, KeyModifiers())
    }

    func testMacroEventRoundTripsWithModifiers() throws {
        let event = MacroEvent(key: .char("r"), modifiers: KeyModifiers(control: true))
        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - Macro

    func testMacroRoundTripsPreservingBodyOrder() throws {
        let macro = Macro(
            id: MacroID("m-deploy"),
            name: "Deploy",
            body: [
                MacroEvent(key: .char("d")),
                MacroEvent(key: .char("u")),
                MacroEvent(key: .enter),
            ])
        let decoded = try roundTrip(macro)
        XCTAssertEqual(decoded, macro)
        XCTAssertEqual(decoded.body.map(\.key), [.char("d"), .char("u"), .enter])
    }

    func testMacroIdentifiableUsesMacroID() {
        let macro = Macro(id: MacroID("abc"), name: "x", body: [MacroEvent(key: .tab)])
        XCTAssertEqual(macro.id, MacroID("abc"))
    }
}
