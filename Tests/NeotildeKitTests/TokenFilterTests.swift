// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// TokenFilter — Critical tier (security). The write-time predicate that keeps
/// secrets out of the learned vocabulary. EP + BVA + adversarial: a positive per
/// exclude vector, negatives that must record, entropy boundaries, and gating of
/// a real store.
final class TokenFilterTests: XCTestCase {
    private let filter = TokenFilter()

    // MARK: deterministic patterns — positives

    func testContainsPasswordTokenSecret() {
        XCTAssertTrue(filter.excludes("password"))
        XCTAssertTrue(filter.excludes("hunter2password"), "substring anywhere")
        XCTAssertTrue(filter.excludes("api_token"))
        XCTAssertTrue(filter.excludes("topsecret"))
    }

    func testContainsIsCaseInsensitive() {
        XCTAssertTrue(filter.excludes("PASSWORD"))
        XCTAssertTrue(filter.excludes("API_TOKEN"))
        XCTAssertTrue(filter.excludes("MySecret"))
    }

    func testGitHubTokenPrefixes() {
        XCTAssertTrue(filter.excludes("ghp_16C7e42F292c6912E7710c838347Ae178B4a"))
        XCTAssertTrue(filter.excludes("gho_abcdef0123456789"))
        XCTAssertTrue(filter.excludes("ghs_abcdef0123456789"))
    }

    func testApiKeyPrefixes() {
        XCTAssertTrue(filter.excludes("sk-abc123DEF456ghi789"), "OpenAI sk- (hyphen)")
        XCTAssertTrue(filter.excludes("sk_live_51HxyzABCdef"), "Stripe sk_ (underscore)")
        XCTAssertTrue(filter.excludes("pk_live_51HxyzABCdef"), "Stripe pk_")
    }

    func testGitHubFineGrainedPatPrefix() {
        XCTAssertTrue(filter.excludes("github_pat_11ABCDEF0abcdef1234567890"))
    }

    // MARK: negatives — must be recorded

    func testNormalCommandsNotExcluded() {
        for token in ["git", "deploy", "kubectl", "README", "main.swift", "/usr/bin/env"] {
            XCTAssertFalse(filter.excludes(token), "\(token) is normal vocabulary and must record")
        }
    }

    func testPrefixMatchIsCaseSensitive() {
        // Real GitHub PATs are lowercase `ghp_`; an uppercased `GHP_` is not a
        // secret, so case-sensitive prefix matching correctly does not exclude it.
        XCTAssertFalse(filter.excludes("GHP_abc"))
    }

    // MARK: entropy backstop

    func testHighEntropyTokenExcludedAtBoundary() {
        // 16 distinct chars → entropy log2(16) = 4.0, exactly the threshold, at
        // exactly the min length — must exclude (the `>=` boundary).
        XCTAssertTrue(filter.excludes("abcdefghijklmnop"))
        // 18 chars — the 16–19 range a min-length of 20 would have leaked.
        XCTAssertTrue(filter.excludes("abcdefghijklmnopqr"))
        // A realistic pasted secret matching no known prefix.
        XCTAssertTrue(filter.excludes("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"))
    }

    func testShortTokenNeverEntropyExcluded() {
        // 15 distinct chars: below min length, and structurally can't reach 4.0
        // bits/char (needs ≥16 symbols) — must not exclude.
        XCTAssertFalse(filter.excludes("abcdefghijklmno"))
    }

    func testLongLowEntropyNotExcluded() {
        XCTAssertFalse(filter.excludes(String(repeating: "a", count: 32)))
        XCTAssertFalse(filter.excludes("aaaaaaaaaabbbbbbbbbb"), "len 20 but entropy 1.0 < 4.0")
    }

    func testEmptyPatternMatchesNothing() {
        // A degenerate empty rule must exclude NOTHING, never everything.
        let containsEmpty = TokenFilter(patterns: [.contains("")], entropyThreshold: nil)
        XCTAssertFalse(containsEmpty.excludes("git"))
        XCTAssertFalse(containsEmpty.excludes("anything"))
        let prefixEmpty = TokenFilter(patterns: [.hasPrefix("")], entropyThreshold: nil)
        XCTAssertFalse(prefixEmpty.excludes("git"))
    }

    func testEntropyThresholdNilDisablesBackstop() {
        var noEntropy = TokenFilter(entropyThreshold: nil)
        noEntropy.patterns = []   // isolate: only the entropy rule could exclude
        XCTAssertFalse(noEntropy.excludes("abcdefghijklmnopqrst"))
    }

    // MARK: shannon entropy — known-answer

    func testShannonEntropyKnownValues() {
        XCTAssertEqual(shannonEntropy(""), 0, accuracy: 1e-9)
        XCTAssertEqual(shannonEntropy("aaaa"), 0, accuracy: 1e-9)
        XCTAssertEqual(shannonEntropy("ab"), 1.0, accuracy: 1e-9)     // 2 symbols, equal
        XCTAssertEqual(shannonEntropy("aabb"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(shannonEntropy("abcd"), 2.0, accuracy: 1e-9)   // log2(4)
    }

    // MARK: integration — gates recording into a real store

    func testGatesRecordingIntoStore() {
        var store = RollingVocabulary()
        let typed = ["git", "ghp_secrettoken12345", "deploy", "my_password_x"]
        for token in typed where !filter.excludes(token) { store.record(token) }

        func learned(_ token: String) -> Bool {
            store.learnedSource(window: .days7)
                .candidates(forPrefix: token)
                .contains { $0.token == token }
        }
        XCTAssertTrue(learned("git"))
        XCTAssertTrue(learned("deploy"))
        XCTAssertFalse(learned("ghp_secrettoken12345"), "secret prefix must never be learned")
        XCTAssertFalse(learned("my_password_x"), "password token must never be learned")
    }
}
