// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Minimal in-memory candidate source for deterministic ranking tests.
private struct FakeSource: CandidateSource {
    let items: [TokenCount]
    func candidates(forPrefix prefix: String) -> [TokenCount] {
        items.filter { $0.token.hasPrefix(prefix) }
    }
}

/// Covers the cross-seed magnitude normalization: a source's raw count scale
/// must not decide the ranking, only the (normalized) bias weight should. Without
/// normalization, a source whose counts run orders of magnitude higher than
/// another's (e.g. a bulk prose corpus vs. a hand-sized CLI seed) always wins
/// regardless of `bias`.
final class DualSeedNormalizationTests: XCTestCase {
    private let empty = FakeSource(items: [])
    // CLI seed: small raw counts (~100), its own scale.
    private let cliSeed = FakeSource(items: [TokenCount(token: "commit", count: 100)])
    // Prose seed: huge raw counts (~100000, 1000x cli), its own scale, distinct token.
    private let proseSeed = FakeSource(items: [TokenCount(token: "comment", count: 100_000)])
    private let cfg = SuggestionConfig(topK: 2, confidenceFloor: 2, seedWeight: 1.0, minPrefix: 2)

    /// bias 0.15 is cli-leaning: after normalization both sources are ~1.0, so
    /// cliW(0.85) > proseW(0.15) and "commit" ranks first, DESPITE the prose seed's
    /// raw count being 1000x larger. This fails against the old (unnormalized) impl,
    /// where prose's raw 100000 always dominates regardless of bias.
    func testCliLeaningBiasCliWinsDespiteHugeProseRawCount() {
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.15, config: cfg, learnedMagnitude: 0,
                                  cliMagnitude: 100, proseMagnitude: 100_000)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["commit", "comment"])
    }

    /// bias 0.85 is prose-leaning: proseW(0.85) > cliW(0.15) once normalized, so
    /// "comment" ranks first.
    func testProseLeaningBiasProseWinsAfterNormalization() {
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.85, config: cfg, learnedMagnitude: 0,
                                  cliMagnitude: 100, proseMagnitude: 100_000)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["comment", "commit"])
    }

    /// A zero magnitude (empty source) must not divide-by-zero or inflate the
    /// contribution to infinity; norm() treats it as zero contribution.
    func testZeroMagnitudeSourceContributesNothing() {
        let cliOnlyMag = FakeSource(items: [TokenCount(token: "commit", count: 100)])
        let s = DualSeedSuggester(learned: empty, cliSeed: cliOnlyMag, proseSeed: proseSeed,
                                  bias: 0.5, config: cfg, learnedMagnitude: 0,
                                  cliMagnitude: 0, proseMagnitude: 100_000)
        // cli's magnitude is 0 -> its norm() is 0 regardless of raw count -> dropped.
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["comment"])
    }

    /// The Layer-2 confident-learned fast path is untouched by normalization
    /// plumbing: enough confident learned candidates still short-circuits to
    /// learned-only, ignoring both seeds entirely (even huge-magnitude ones).
    func testConfidentLearnedFastPathStillReturnsLearnedOnly() {
        let learned = FakeSource(items: [TokenCount(token: "comrade", count: 9),
                                         TokenCount(token: "combine", count: 5)])
        let s = DualSeedSuggester(learned: learned, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.5, config: cfg, learnedMagnitude: 9,
                                  cliMagnitude: 100, proseMagnitude: 100_000)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["comrade", "combine"])
    }
}
