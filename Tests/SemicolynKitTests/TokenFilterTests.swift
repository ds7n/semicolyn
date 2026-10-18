// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// TokenFilter — Critical tier (security). The write-time predicate that keeps
/// secrets out of the learned vocabulary. EP + BVA + adversarial: a positive per
/// exclude vector, negatives that must record, entropy boundaries, and gating of
/// a real store.
final class TokenFilterTests: XCTestCase {
    private let filter = TokenFilter()

    // MARK: deterministic patterns — positives

    func testContainsPasswordTokenSecret() {
        // Bare "password" is an ordinary word now (spec 6.9); see testOrdinaryWordsAllowed.
        XCTAssertTrue(filter.excludes("password1"))
        XCTAssertTrue(filter.excludes("hunter2password"), "substring anywhere")
        XCTAssertTrue(filter.excludes("api_token"))
        XCTAssertTrue(filter.excludes("topsecret"))
    }

    // MARK: ordinary words and hex (Task 17, spec 6.9)

    func testOrdinaryWordsAllowed() {
        for w in ["tokens", "Tokens", "TOKENS", "password", "Passwords", "PASSWORD", "secretly", "secretary",
                  "tokenizer", "passwordless", "tokenization", "secretariat", "Secrete"] {
            XCTAssertFalse(filter.excludes(w), w)
        }
    }

    func testSecretShapesStillExcluded() {
        for w in ["password1", "mypassword", "Password!", "--password", "passwords!", "token=abc", "GITHUB_TOKEN",
                  "api_token", "tokenABC", "secret_key", "MY_SECRET", "secrets.yaml", "x-secret",
                  "tokensx", "secretsauce", "passwordsx"] {
            XCTAssertTrue(filter.excludes(w), w)
        }
    }

    func testEmptyNeedleNeverMatches() {
        XCTAssertFalse(TokenFilter(patterns: [.containsExceptWords("", [])], entropyThreshold: nil).excludes("anything"))
    }

    func testContainsExceptWordsDirect() {
        let f = TokenFilter(patterns: [.containsExceptWords("foo", ["foos"])], entropyThreshold: nil)
        XCTAssertFalse(f.excludes("foos"))
        XCTAssertFalse(f.excludes("FOOS"))
        XCTAssertTrue(f.excludes("foo"), "needle itself not in allowed set")
        XCTAssertFalse(f.excludes("foos."), "trailing clause punctuation ignored")
        XCTAssertTrue(f.excludes("foos!"))
        XCTAssertFalse(f.excludes("bar"))
    }

    func testClausePunctuationAfterAllowedWordAllowed() {
        for w in ["passwords,", "tokens.", "Secret;", "token:"] {
            XCTAssertFalse(filter.excludes(w), w)
        }
    }

    func testOtherSuffixesAfterAllowedWordExcluded() {
        for w in ["Password!", "secrets.yaml", "tokens.json", "password1,", ".tokens", ",tokens"] {
            XCTAssertTrue(filter.excludes(w), w)
        }
    }

    func testUppercaseNeedleAndMixedCaseAllowedSet() {
        let f = TokenFilter(patterns: [.containsExceptWords("FOO", ["foos"])], entropyThreshold: nil)
        XCTAssertTrue(f.excludes("xfoo"), "uppercase needle still matches lowercased token")
        XCTAssertFalse(f.excludes("foos"))
        let g = TokenFilter(patterns: [.containsExceptWords("foo", ["FOOS"])], entropyThreshold: nil)
        XCTAssertFalse(g.excludes("foos"), "uppercase allowed entry still allows")
    }

    func testTurkishDottedIFailsSafe() {
        // lowercased() yields "i" + combining dot, which is not the allowed "tokenize".
        XCTAssertTrue(filter.excludes("TOKEN\u{130}ZE"))
    }

    func testHexZeroXPrefix() {
        let unit = "deadbeef"
        XCTAssertTrue(filter.excludes("0x" + String(repeating: unit, count: 4)), "0x + 32")
        XCTAssertTrue(filter.excludes("0X" + String(repeating: unit, count: 4)), "0X + 32")
        XCTAssertFalse(filter.excludes("0x" + String(repeating: unit, count: 3) + "deadbee"), "0x + 31")
        XCTAssertFalse(filter.excludes("0x" + "deadbeeg" + String(repeating: unit, count: 3)), "non-hex after prefix")
    }

    func testHexLengthBoundary() {
        let unit = "deadbeef"  // low entropy, so only the hex rule can decide
        XCTAssertFalse(filter.excludes(String(repeating: unit, count: 3) + "deadbee"), "31 hex")
        XCTAssertTrue(filter.excludes(String(repeating: unit, count: 4)), "32 hex")
        XCTAssertTrue(filter.excludes(String(repeating: unit, count: 5)), "40 hex")
        XCTAssertTrue(filter.excludes(String(repeating: unit, count: 8)), "64 hex")
    }

    func testHexMixedCaseExcluded() {
        XCTAssertTrue(filter.excludes(String(repeating: "DeadBEEF", count: 4)))
    }

    func testShortHexAllowed() {
        XCTAssertFalse(filter.excludes("a1b2c3d"), "7 char git sha")
        XCTAssertFalse(filter.excludes("a1b2c3d4e5f6"), "12 char git sha")
    }

    func testThirtyTwoCharsWithOneNonHexNotHexExcluded() {
        // Low entropy: nothing else in the filter excludes it, so the hex rule must not.
        XCTAssertFalse(filter.excludes(String(repeating: "deadbeef", count: 3) + "deadbeeg"))
        // High entropy variant is excluded, but by the entropy backstop (H > 4.0), not hex.
        let noEntropy = TokenFilter(entropyThreshold: nil)
        XCTAssertFalse(noEntropy.excludes("0123456789abcdef0123456789abcdeg"))
        XCTAssertTrue(filter.excludes("0123456789abcdef0123456789abcdeg"))
    }

    func testHexRuleIndependentOfEntropyBackstop() {
        let noEntropy = TokenFilter(entropyThreshold: nil)
        XCTAssertTrue(noEntropy.excludes(String(repeating: "deadbeef", count: 4)))
        XCTAssertFalse(noEntropy.excludes(String(repeating: "deadbeef", count: 3) + "deadbee"))
    }

    func testContainsIsCaseInsensitive() {
        XCTAssertTrue(filter.excludes("PASSWORD1"))
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
        // "z" not "a": 32 x "a" is pure hex and excluded by the Task 17 hex rule.
        XCTAssertFalse(filter.excludes(String(repeating: "z", count: 32)))
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

    // MARK: - L5 added credential-format prefixes

    func testAwsAccessKeyExcluded() {
        XCTAssertTrue(filter.excludes("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(filter.excludes("ASIAIOSFODNN7EXAMPLE"))
    }

    func testGoogleApiKeyExcluded() {
        XCTAssertTrue(filter.excludes("AIzaSyD-EXAMPLE_key_1234567890abcdefg"))
    }

    func testStripeLiveKeysExcluded() {
        XCTAssertTrue(filter.excludes("sk_live_abc123DEF456"))
        XCTAssertTrue(filter.excludes("rk_live_abc123DEF456"))
    }

    func testSlackTokensExcluded() {
        XCTAssertTrue(filter.excludes("xoxb-1234-5678-abcdefg"))
        XCTAssertTrue(filter.excludes("xoxp-1111-2222-zzz"))
        // Cover the remaining Slack token prefixes (bot/app/user/refresh/socket).
        XCTAssertTrue(filter.excludes("xoxa-2222-3333-yyy"))
        XCTAssertTrue(filter.excludes("xoxr-4444-5555-www"))
        XCTAssertTrue(filter.excludes("xoxs-6666-7777-vvv"))
    }

    func testGithubFineGrainedPatExcluded() {
        // Already present via `github_pat_` in the shipped defaults — assert it stays.
        XCTAssertTrue(filter.excludes("github_pat_11ABCDEFG_examplekeymaterial"))
    }

    func testBenignTokenNotExcludedByL5Prefixes() {
        // A normal command/arg that shares no credential prefix must NOT be excluded.
        XCTAssertFalse(filter.excludes("kubectl"))
        XCTAssertFalse(filter.excludes("git"))
        // "asia" as a plain word is lowercase — the ASIA prefix is case-sensitive.
        XCTAssertFalse(filter.excludes("asia-region"))
    }

    // MARK: - L5 structural (JWT / PEM)

    func testJwtExcluded() {
        // Three base64url segments, first starts with the standard `eyJ` header.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertTrue(filter.excludes(jwt))
    }

    func testPemPrivateKeyHeaderExcluded() {
        XCTAssertTrue(filter.excludes("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(filter.excludes("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    func testNonJwtDottedTokenNotExcluded() {
        // A dotted token that is NOT a JWT (doesn't start with eyJ, wrong shape)
        // must not be excluded by the structural check — e.g. a hostname or version.
        XCTAssertFalse(filter.excludes("example.com.au"))
        XCTAssertFalse(filter.excludes("1.2.3"))
    }

    func testPublicPemHeaderNotExcluded() {
        // A PUBLIC key / certificate header is not a secret — must NOT be excluded
        // by the PEM check (only PRIVATE KEY headers are secret-bearing).
        XCTAssertFalse(filter.excludes("-----BEGIN PUBLIC KEY-----"))
        XCTAssertFalse(filter.excludes("-----BEGIN CERTIFICATE-----"))
    }

    // MARK: - isPatternAdjacent (soft L5 signal)

    func testPatternAdjacentFlagsSoftEntropyBand() {
        let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
        // A 20-char token engineered to land in [3.25, 4.0): high but sub-threshold.
        let token = "aabbccddeeffgghhiijj"  // 10 distinct pairs → H = log2(10) ≈ 3.32
        XCTAssertFalse(filter.excludes(token), "precondition: not a hard-excluded secret")
        XCTAssertTrue(filter.isPatternAdjacent(token), "soft-band token must be flagged low-confidence")
    }

    func testPatternAdjacentIgnoresLowEntropyToken() {
        let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
        let token = "aaaaaaaaaaaaaaaaaaaa"  // H = 0 → well below the band
        XCTAssertFalse(filter.isPatternAdjacent(token))
    }

    func testPatternAdjacentIgnoresShortToken() {
        let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
        XCTAssertFalse(filter.isPatternAdjacent("abc123"), "below entropyMinLength — never flagged")
    }

    func testPatternAdjacentFalseWhenBackstopDisabled() {
        let filter = TokenFilter(entropyThreshold: nil)
        XCTAssertFalse(filter.isPatternAdjacent("aabbccddeeffgghhiijj"))
    }
}
