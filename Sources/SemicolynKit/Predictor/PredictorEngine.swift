// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The runtime facade: one type the app records into and queries for suggestions,
/// composing the write-time privacy filter, the learned windowed stores, the
/// pinned seed, and the seed-deferring ranker. Holds no I/O — the app loads its
/// inputs from ``SeedStore`` / ``LearnedStore`` and flushes `state` back. See
/// `2026-06-21-predictor-engine-design`.
public struct PredictorEngine: Sendable {
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

    /// L6 frequency-graduation tier — ephemeral, never persisted (not part of
    /// `LearnedState`). Defers learning until a token recurs across N distinct
    /// contexts, so a once-typed secret never enters the suggestable store.
    private var graduation = GraduationTier()

    /// The current learned state, for the app to flush via ``LearnedStore``.
    public var state: LearnedState { learned }

    /// Learn `count` occurrences of `token`, optionally as the successor of
    /// `previous`. Write-time privacy is applied here, once: an excluded `token` is
    /// learned nowhere; an excluded `previous` suppresses only the adjacency (the
    /// non-excluded `token` is still a unigram). The data simply isn't recorded, so
    /// reads never need to filter.
    ///
    /// L6: tokens are deferred until they recur across N distinct contexts; see
    /// ``GraduationTier``.
    ///
    /// L7: `echoConfirmed` and `optedOut` thread through to ``LearnConfidence``.
    /// A token with `.low` confidence graduates count-only (no stored literal) so it
    /// never surfaces as a completion — the core secret-exclusion invariant.
    public mutating func record(_ token: String, count: UInt32 = 1, after previous: String? = nil,
                                echoConfirmed: Bool = true, optedOut: Bool = false) {
        guard !filter.excludes(token) else { return }
        // L7: derive graduation confidence from all visible layers. High iff the
        // echo oracle confirmed the character, the line was not marked opted-out,
        // and the token is not in the soft entropy band (L5 near-miss).
        let confidence: LearnConfidence =
            (echoConfirmed && !optedOut && !filter.isPatternAdjacent(token)) ? .high : .low
        // L6: defer until the token has recurred across N distinct contexts. `admit`
        // returns the occurrences to persist now (empty while deferred; the full
        // backfill on graduation; just this one once already graduated).
        for occ in graduation.admit(token: token, previous: previous, count: count, confidence: confidence) {
            let storeLiteral = (occ.confidence == .high)
            learned.unigram.record(occ.token, count: occ.count, storeLiteral: storeLiteral)
            if let prev = occ.previous, !filter.excludes(prev) {
                learned.bigram.record(previous: prev, next: occ.token, count: occ.count,
                                      storeLiteral: storeLiteral)
            }
        }
    }

    /// Clear the ephemeral graduation tier (context/host switch / incognito). The
    /// persistent learned store is untouched — only un-graduated deferrals are lost.
    public mutating func resetGraduation() {
        graduation.reset()
    }

    /// Mark an input-line boundary for surgical forget-last-line (App calls at Enter).
    public mutating func beginLine() { graduation.beginLine() }

    /// Drop the current line's still-pending (un-graduated) tokens — the "oops, I just
    /// typed a secret" tool. A clean ephemeral delete: no CMS decrement, no index surgery.
    public mutating func forgetLastLine() { graduation.forgetLastLine() }

    /// Wipe all user-derived learned state (persistent learned axes + ephemeral output
    /// + L6 tier). The bundled seed is a `let` and is untouched. Panic-purge's Kit half.
    public mutating func purgeLearned() {
        learned = .empty
        output.clear()
        graduation.reset()
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
