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
    /// Ephemeral output-token context (not persisted); leads suggestions.
    private var output: OutputHarvest
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
        self.output = OutputHarvest()
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

    /// Harvest tokens from command `output` so they surface as completions. Each
    /// whitespace-delimited token is privacy-filtered (an excluded token is
    /// harvested nowhere) before entering the ephemeral store.
    public mutating func harvest(output: String) {
        let tokens = output
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !filter.excludes($0) }
        self.output.harvest(tokens)
    }

    /// Drop harvested output tokens — for a context change (host switch, incognito).
    public mutating func clearHarvest() {
        output.clear()
    }

    /// Up to `config.topK` suggestions for `prefix`. Just-harvested output tokens
    /// lead (recency order, axis-independent), then next-token (bigram) candidates
    /// after `previous` when given, otherwise single-word (unigram) candidates,
    /// each deferring to the seed per-prefix via the same ``SeededSuggester``.
    /// Duplicates collapse to their first (harvested) position; a missing seed
    /// yields learned-only results.
    public func suggestions(forPrefix prefix: String, after previous: String? = nil) -> [String] {
        guard config.topK > 0 else { return [] }   // harvest path isn't otherwise capped
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
        let base = SeededSuggester(learned: learnedSource, seed: seedSource, config: config)
            .suggestions(forPrefix: prefix)

        // Harvested output leads (already newest-first); learned/seed fill the rest.
        let harvested = output.candidates(forPrefix: prefix).map { $0.token }
        var seen = Set<String>()
        var merged: [String] = []
        for token in harvested + base {
            guard seen.insert(token).inserted else { continue }
            merged.append(token)
            if merged.count == config.topK { break }
        }
        return merged
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
