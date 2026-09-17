// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Precedence for the tmux prefix byte gestures send:
///   manual override (user-set) > auto-learned (per-host) > this-session discovery > C-b default.
/// The manual override and learned values are raw tmux strings ("C-a"); the session-discovered
/// value and the default are already bytes. A string that does not parse is ignored (falls
/// through to the next source), so a typo never silently disables gestures.
final class TmuxPrefixResolutionTests: XCTestCase {
    private let cB: UInt8 = 0x02   // tmux default C-b
    private let cA: UInt8 = 0x01   // C-a

    // EP: nothing configured, no discovery -> C-b default.
    func testDefaultWhenNothingKnown() {
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: nil, learned: nil, discovered: nil, fallback: cB),
            cB)
    }

    // EP: session discovery only -> use it.
    func testDiscoveredUsedWhenNoOverrideOrLearned() {
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: nil, learned: nil, discovered: cA, fallback: cB),
            cA)
    }

    // EP: learned beats session discovery (resume has no discovery; learned carries the day).
    func testLearnedBeatsDiscovered() {
        // learned says C-a, this session discovered nothing -> C-a.
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: nil, learned: "C-a", discovered: nil, fallback: cB),
            cA)
    }

    // Precedence: manual override wins over BOTH learned and discovered, even when they disagree.
    func testOverrideWinsOverLearnedAndDiscovered() {
        // override C-a; learned + discovered both say C-b -> override C-a wins.
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: "C-a", learned: "C-b", discovered: cB, fallback: cB),
            cA)
    }

    // Adversarial: an unparseable override is IGNORED, falling through to learned (not a crash,
    // not a silent C-b that would break a learned C-a host).
    func testUnparseableOverrideFallsThroughToLearned() {
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: "nonsense", learned: "C-a", discovered: nil, fallback: cB),
            cA)
    }

    // Adversarial: an unparseable learned value is IGNORED, falling through to discovered.
    func testUnparseableLearnedFallsThroughToDiscovered() {
        XCTAssertEqual(
            resolveTmuxPrefixByte(override: nil, learned: "garbage", discovered: cA, fallback: cB),
            cA)
    }
}
