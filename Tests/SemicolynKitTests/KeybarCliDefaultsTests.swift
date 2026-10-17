// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The default middle keys and their swipes, chosen by CLI symbol frequency
/// (tap = the six most used; every bracket pair lives on one key).
final class KeybarCliDefaultsTests: XCTestCase {

    private let expected: [(tap: String, up: String, down: String)] = [
        ("-", "_", "="),
        ("|", ">", ";"),
        ("/", "\\", "*"),
        ("$", "(", ")"),
        ("\"", "'", ":"),
        (".", "{", "}"),
    ]

    func testDefaultMiddleIsTheSixCliKeysThenFn() {
        XCTAssertEqual(KeybarLayout.default.middle,
                       expected.map { KeybarSlot.symbol($0.tap) } + [.fn])
    }

    func testEachDefaultKeyHasItsUpAndDownSwipe() {
        for k in expected {
            XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol(k.tap)),
                           SwipeSecondaries(up: .literal(k.up), down: .literal(k.down)), "key \(k.tap)")
        }
    }

    /// Every symbol the default middle reaches, read from the real layout + defaults.
    private func reachable() -> [(tap: String, up: String?, down: String?)] {
        KeybarLayout.default.middle.compactMap { slot in
            guard case .symbol(let s) = slot else { return nil }
            let d = FixedKeyDefaults.defaults(for: .symbol(s))
            func text(_ v: SecondaryValue?) -> String? {
                if case .literal(let t) = v { return t }
                return nil
            }
            return (s, text(d.up), text(d.down))
        }
    }

    func testEveryBracketPairSharesOneKey() {
        let keys = reachable()
        for (open, close) in [("(", ")"), ("{", "}")] {
            let owner = keys.first { $0.up == open }
            XCTAssertNotNil(owner, "\(open) must be a swipe-up on a default key")
            XCTAssertEqual(owner?.down, close, "\(close) must be on the same key as \(open)")
        }
    }

    func testDefaultBarReachesEighteenDistinctSymbols() {
        let all = reachable().flatMap { [$0.tap, $0.up, $0.down].compactMap { $0 } }
        XCTAssertEqual(all.count, 18)
        XCTAssertEqual(Set(all).count, 18)
    }

    func testDotNoLongerSendsDoubleDot() {
        XCTAssertNotEqual(FixedKeyDefaults.defaults(for: .symbol(".")).up, .literal(".."))
    }
}
