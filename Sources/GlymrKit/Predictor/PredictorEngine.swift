// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The runtime facade: one type the app records into and queries for suggestions,
/// composing the write-time privacy filter, the learned windowed stores, the
/// pinned seed, and the seed-deferring ranker. Holds no I/O — the app loads its
/// inputs from ``SeedStore`` / ``LearnedStore`` and flushes `state` back. See
/// `2026-06-21-predictor-engine-design`.
public struct PredictorEngine {
    private var learned: LearnedState
    private let seed: PredictorSeed?
    /// Write-time exclusion rules — consulted only by `record`, never by reads.
    public var filter: TokenFilter
    /// Ranking knobs (top-K, confidence floor, seed weight).
    public var config: SuggestionConfig
    /// Which rolling pre-aggregate suggestions read.
    public var window: RollingWindow

    public init(learned: LearnedState, seed: PredictorSeed?,
                filter: TokenFilter = .init(), config: SuggestionConfig = .init(),
                window: RollingWindow = .days30) {
        self.learned = learned
        self.seed = seed
        self.filter = filter
        self.config = config
        self.window = window
    }

    /// The current learned state, for the app to flush via ``LearnedStore``.
    public var state: LearnedState { learned }

    /// Learn `count` occurrences of `token`, optionally as the successor of
    /// `previous`. Write-time privacy is applied here, once: an excluded `token` is
    /// learned nowhere; an excluded `previous` suppresses only the adjacency (the
    /// non-excluded `token` is still a unigram). The data simply isn't recorded, so
    /// reads never need to filter.
    public mutating func record(_ token: String, count: UInt32 = 1, after previous: String? = nil) {
        guard !filter.excludes(token) else { return }
        learned.unigram.record(token, count: count)
        if let previous, !filter.excludes(previous) {
            learned.bigram.record(previous: previous, next: token, count: count)
        }
    }

    /// Up to `config.topK` suggestions for `prefix`: next-token (bigram) candidates
    /// after `previous` when given, otherwise single-word (unigram) candidates.
    /// Each axis defers to the seed per-prefix via the same ``SeededSuggester``;
    /// a missing seed yields learned-only results.
    public func suggestions(forPrefix prefix: String, after previous: String? = nil) -> [String] {
        let learnedSource: any CandidateSource
        let seedSource: any CandidateSource
        // An empty `previous` means "no preceding token" (start of line) — fall back
        // to the unigram axis rather than querying a dead bigram axis (no composite
        // key has an empty previous, so it would always return nothing).
        if let previous, !previous.isEmpty {
            learnedSource = learned.bigram.nextSource(after: previous, window: window)
            seedSource = seed?.bigram.nextSource(after: previous) ?? Self.emptySource()
        } else {
            learnedSource = learned.unigram.learnedSource(window: window)
            seedSource = seed?.unigram ?? Self.emptySource()
        }
        return SeededSuggester(learned: learnedSource, seed: seedSource, config: config)
            .suggestions(forPrefix: prefix)
    }

    /// Seal the day for both learned axes — the app calls this at user-local
    /// midnight.
    public mutating func rollover() {
        learned.unigram.rollover()
        learned.bigram.rollover()
    }

    /// An always-empty candidate source — the seed stand-in for a seedless engine,
    /// so the ranker's fill path simply adds nothing.
    private static func emptySource() -> AggregateCandidateSource { AggregateCandidateSource([]) }
}
