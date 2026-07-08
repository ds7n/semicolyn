// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class FixedKeySecondaryTests: XCTestCase {
    // Codable round-trip for each SecondaryValue case.
    func testSecondaryValueLiteralRoundTrip() throws {
        let v = SecondaryValue.literal("_")
        XCTAssertEqual(try JSONDecoder().decode(SecondaryValue.self, from: JSONEncoder().encode(v)), v)
    }
    func testSecondaryValueKeyRoundTrip() throws {
        let v = SecondaryValue.key(.tab, KeyModifiers(shift: true))
        XCTAssertEqual(try JSONDecoder().decode(SecondaryValue.self, from: JSONEncoder().encode(v)), v)
    }
    func testSwipeSecondariesRoundTrip() throws {
        let s = SwipeSecondaries(up: .literal("_"), down: .key(.function(5), KeyModifiers()))
        XCTAssertEqual(try JSONDecoder().decode(SwipeSecondaries.self, from: JSONEncoder().encode(s)), s)
    }
    func testFixedKeyIDRoundTrip() throws {
        for id in [FixedKeyID.symbol("-"), .tab, .fkey(3)] {
            XCTAssertEqual(try JSONDecoder().decode(FixedKeyID.self, from: JSONEncoder().encode(id)), id)
        }
    }
    // Built-in defaults: representative exact values.
    func testDefaultDashToUnderscore() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("-")).up, .literal("_"))
    }
    func testDefaultSlashToBackslash() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("/")).up, .literal("\\"))
    }
    func testDefaultTabToShiftTab() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .tab).up, .key(.tab, KeyModifiers(shift: true)))
    }
    func testDefaultFKeyEmpty() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .fkey(1)), SwipeSecondaries())
    }
    func testDefaultUnknownSymbolEmpty() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("Z")), SwipeSecondaries())
    }
    // Resolution: override wins; absent → default.
    func testResolveOverrideWins() {
        let ov: [FixedKeyID: SwipeSecondaries] = [.symbol("-"): SwipeSecondaries(up: .literal("X"))]
        XCTAssertEqual(resolveSecondaries(for: .symbol("-"), overrides: ov).up, .literal("X"))
    }
    func testResolveFallsBackToDefault() {
        XCTAssertEqual(resolveSecondaries(for: .symbol("-"), overrides: [:]).up, .literal("_"))
    }
    func testResolveNoDefaultNoOverrideIsEmpty() {
        XCTAssertEqual(resolveSecondaries(for: .fkey(2), overrides: [:]), SwipeSecondaries())
    }
}
