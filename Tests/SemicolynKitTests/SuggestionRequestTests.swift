// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SuggestionRequestTests: XCTestCase {
    // EP: non-empty current, not secret, not opted-out, count >= minPrefix -> blended, next-word allowed.
    func testBlendedAllowsNextWordWhenClean() {
        let r = suggestionRequest(current: "commit", previous: "git", precedingToken: "git",
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .blended(current: "commit", previous: "git", allowNextWord: true))
    }

    // Adversarial: opted-out line still allows completions but suppresses the next-word half.
    func testBlendedSuppressesNextWordWhenOptedOut() {
        let r = suggestionRequest(current: "commit", previous: nil, precedingToken: nil,
                                  lineOptedOut: true, minPrefix: 2)
        XCTAssertEqual(r, .blended(current: "commit", previous: nil, allowNextWord: false))
    }

    // Adversarial: current is an L4b secret VALUE token (`--password hunter2`) -> completions
    // still allowed, next-word half suppressed so the secret's existence never leaks.
    func testBlendedSuppressesNextWordWhenCurrentIsSecretValue() {
        let r = suggestionRequest(current: "hunter2", previous: nil, precedingToken: "--password",
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .blended(current: "hunter2", previous: nil, allowNextWord: false))
    }

    // BVA: current below minPrefix floor -> completions allowed, next-word suppressed.
    func testBlendedSuppressesNextWordBelowMinPrefixFloor() {
        let r = suggestionRequest(current: "a", previous: nil, precedingToken: nil,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .blended(current: "a", previous: nil, allowNextWord: false))
    }

    // BVA: current exactly at minPrefix floor -> next-word allowed.
    func testBlendedAllowsNextWordAtMinPrefixFloor() {
        let r = suggestionRequest(current: "ab", previous: nil, precedingToken: nil,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .blended(current: "ab", previous: nil, allowNextWord: true))
    }

    // EP: current empty, previous usable -> nextWord(after: previous)  [Trigger A]
    func testNextWordOnSpaceCommit() {
        let r = suggestionRequest(current: "", previous: "git", precedingToken: "git",
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "git"))
    }

    // EP: current empty, no usable previous -> none (start of line)
    func testNoneAtLineStart() {
        let r = suggestionRequest(current: "", previous: nil, precedingToken: nil,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }
    func testNoneWhenPreviousEmptyString() {
        let r = suggestionRequest(current: "", previous: "", precedingToken: nil,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // Trigger A is NOT gated by minPrefix (bigram path exempt): empty current, short previous still fires.
    func testTriggerANotGatedByMinPrefix() {
        let r = suggestionRequest(current: "", previous: "a", precedingToken: "a",
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "a"))
    }
}
