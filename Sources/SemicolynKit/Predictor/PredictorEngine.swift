// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The runtime facade: one type the app records into and queries for suggestions,
/// composing the write-time privacy filter, the learned windowed stores, the
/// pinned seed, and the seed-deferring ranker. Holds no I/O, the app loads its
/// inputs from ``SeedStore`` / ``LearnedStore`` and flushes `state` back. See
/// `2026-06-21-predictor-engine-design`.
public struct PredictorEngine: Sendable {
    private var learned: LearnedState
    private let seed: PredictorSeed?
    /// Prose-domain seed (e.g. English/code-comment vocabulary), weighted against
    /// `seed` (the CLI-domain seed) by `proseBias(context)` in the fill path. `nil`
    /// keeps the fill path CLI-only regardless of context.
    private let proseSeed: PredictorSeed?
    /// Ephemeral output-token context (not persisted); leads suggestions.
    private var output: OutputHarvest
    /// Write-time exclusion rules, consulted only by `record`, never by reads.
    public var filter: TokenFilter
    /// Ranking knobs (top-K, confidence floor, seed weight).
    public var config: SuggestionConfig
    /// Which rolling pre-aggregate suggestions read.
    public var window: RollingWindow
    /// `seed.unigram.magnitude()`, cached at init since `seed` is immutable, so
    /// `suggestions` never re-enumerates the whole CLI vocabulary per keystroke.
    private let cliMagnitude: Double
    /// `proseSeed.unigram.magnitude()`, cached at init for the same reason as
    /// `cliMagnitude`.
    private let proseMagnitude: Double

    public init(learned: LearnedState, seed: PredictorSeed?,
                proseSeed: PredictorSeed? = nil,
                filter: TokenFilter = .init(), config: SuggestionConfig = .init(),
                window: RollingWindow = .days30) {
        self.learned = learned
        self.seed = seed
        self.proseSeed = proseSeed
        self.cliMagnitude = seed.map { Double($0.unigram.magnitude()) } ?? 0
        self.proseMagnitude = proseSeed.map { Double($0.unigram.magnitude()) } ?? 0
        self.output = OutputHarvest()
        self.filter = filter
        self.config = config
        self.window = window
    }

    /// L6 frequency-graduation tier, ephemeral, never persisted (not part of
    /// `LearnedState`). Defers learning until a token recurs across N distinct
    /// contexts, so a once-typed secret never enters the suggestable store.
    private var graduation = GraduationTier()

    /// The current learned state, for the app to flush via ``LearnedStore``.
    public var state: LearnedState { learned }

    /// Learn `count` occurrences of `token`, optionally as the successor of
    /// `previous`. Write-time privacy is applied here, once: an excluded `token` is
    /// learned nowhere; an excluded `previous` suppresses only the adjacency (the
    /// non-excluded `token` is still a unigram). Data recorded through this path
    /// never needs read-time filtering; but `suggestions` also re-applies `filter`
    /// as a safety net, since a bundled seed (unlike `record`) can carry an
    /// excluded token (e.g. profanity) that never passed through this gate.
    ///
    /// L6: tokens are deferred until they recur across N distinct contexts; see
    /// ``GraduationTier``.
    ///
    /// L7: `echoConfirmed` and `optedOut` thread through to ``LearnConfidence``.
    /// A token with `.low` confidence graduates count-only (no stored literal) so it
    /// never surfaces as a completion, the core secret-exclusion invariant.
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
    /// persistent learned store is untouched, only un-graduated deferrals are lost.
    public mutating func resetGraduation() {
        graduation.reset()
    }

    /// Mark an input-line boundary for surgical forget-last-line (App calls at Enter).
    public mutating func beginLine() { graduation.beginLine() }

    /// Drop the current line's still-pending (un-graduated) tokens, the "oops, I just
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
        // Strip ANSI/CSI/OSC escapes first so color codes and cursor moves never
        // become suggestable tokens (they have no interior whitespace, so a raw
        // split would fuse `\u{1b}[…m` onto the following word).
        let tokens = stripANSI(output)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !filter.excludes($0) }
        self.output.harvest(tokens)
    }

    /// Drop harvested output tokens, for a context change (host switch, incognito).
    public mutating func clearHarvest() {
        output.clear()
    }

    /// Up to `config.topK` suggestions for `prefix`. Just-harvested output tokens
    /// lead (recency order, axis-independent), then next-token (bigram) candidates
    /// after `previous` when given, otherwise single-word (unigram) candidates,
    /// each deferring to the CLI and prose seeds per-prefix via ``DualSeedSuggester``,
    /// weighted by `proseBias(context)`. Duplicates collapse to their first
    /// (harvested) position; a missing seed yields learned-only results. With no
    /// `proseSeed` (or a default, all-nil `context`), the fill path's prose
    /// contribution is zero and output matches the CLI-only ranking exactly.
    public func suggestions(forPrefix prefix: String, after previous: String? = nil,
                            context: PredictionContext = .init()) -> [String] {
        // Min-prefix floor on the FROM-SCRATCH path only. A usable `previous` means the
        // caller wants next-token (bigram) suggestions, which are valid with an empty
        // word-prefix; only the no-preceding-token case needs typed input (bugs 3/4).
        let hasUsablePrevious = (previous?.isEmpty == false)
        guard hasUsablePrevious || prefix.count >= config.minPrefix else { return [] }
        guard config.topK > 0 else { return [] }   // harvest path isn't otherwise capped
        let learnedSource: any CandidateSource
        let cliSeedSource: any CandidateSource
        let proseSeedSource: any CandidateSource
        // An empty `previous` means "no preceding token" (start of line), fall back
        // to the unigram axis rather than querying a dead bigram axis (no composite
        // key has an empty previous, so it would always return nothing).
        if let previous, !previous.isEmpty {
            learnedSource = learned.bigram.nextSource(after: previous, window: window)
            cliSeedSource = seed?.bigram.nextSource(after: previous) ?? Self.emptySource()
            proseSeedSource = proseSeed?.bigram.nextSource(after: previous) ?? Self.emptySource()
        } else {
            learnedSource = learned.unigram.learnedSource(window: window)
            cliSeedSource = seed?.unigram ?? Self.emptySource()
            proseSeedSource = proseSeed?.unigram ?? Self.emptySource()
        }

        // Each source's own p90 count magnitude, the scale `DualSeedSuggester` divides
        // by before applying the bias weight, so a source's raw size (e.g. a large
        // prose corpus vs. a small CLI seed) never dominates on its own. The learned
        // magnitude tracks the same window as `learnedSource` above, recomputed per
        // call since `learned` is the mutable rolling store; the seed magnitudes are
        // constant (the seeds are `let`) and cached at init, see `cliMagnitude` /
        // `proseMagnitude`.
        //
        // DELIBERATE proxy: `cliMagnitude`/`proseMagnitude` are each seed's UNIGRAM
        // p90 magnitude, and that same scalar is reused below on the BIGRAM query
        // path too (there is no separate `BigramVocabulary.magnitude`). Bigram counts
        // for a given seed track that seed's unigram count scale closely enough that
        // the unigram magnitude is a stable, deterministic per-seed normalizer for
        // both axes. An exact per-axis bigram magnitude is a possible future
        // refinement, not required for correct relative ranking today.
        let learnedMag = Double(learned.unigram.magnitude(window: window))
        let cliMag = cliMagnitude
        let proseMag = proseMagnitude

        let bias = proseBias(context)
        // Over-fetch beyond `config.topK`: the merge loop below re-applies `filter`
        // (a bundled seed can carry an excluded token, e.g. profanity, that never
        // passed through `record`'s write-time gate). If `DualSeedSuggester` only
        // returned `topK` candidates, dropping an excluded one there would under-fill
        // the result instead of backfilling from the next clean candidate.
        let overfetchLimit = max(config.topK * 3, config.topK + 12)
        let base = DualSeedSuggester(learned: learnedSource, cliSeed: cliSeedSource,
                                     proseSeed: proseSeedSource, bias: bias, config: config,
                                     learnedMagnitude: learnedMag, cliMagnitude: cliMag,
                                     proseMagnitude: proseMag)
            .suggestions(forPrefix: prefix, limit: overfetchLimit)

        // Harvested output leads (already newest-first); learned/seed fill the rest.
        let harvested = output.candidates(forPrefix: prefix).map { $0.token }
        var seen = Set<String>()
        var merged: [String] = []
        for token in harvested + base {
            if filter.excludes(token) { continue }
            guard seen.insert(token).inserted else { continue }
            merged.append(token)
            if merged.count == config.topK { break }
        }
        return merged
    }

    /// True iff `word` is a "terminal" vocabulary word: a known token in at least one
    /// unigram source (learned/CLI/prose) that NOTHING longer extends. Gates the
    /// next-word Trigger B so it fires only on genuinely-finished words, not partials
    /// the user is still typing (spec addendum 2026-08-21, Fix 1). Empty `word` is
    /// never terminal.
    public func isTerminalWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var sources: [any CandidateSource] = [learned.unigram.learnedSource(window: window)]
        if let seed { sources.append(seed.unigram) }
        if let proseSeed { sources.append(proseSeed.unigram) }
        var known = false
        for src in sources {
            for tc in src.candidates(forPrefix: word) {
                if tc.token == word { known = true }
                else if tc.token.count > word.count { return false }  // something extends it
            }
        }
        return known
    }

    /// Seal the day for both learned axes, the app calls this at user-local
    /// midnight.
    public mutating func rollover() {
        learned.unigram.rollover()
        learned.bigram.rollover()
    }

    /// An always-empty candidate source, the seed stand-in for a seedless engine,
    /// so the ranker's fill path simply adds nothing.
    private static func emptySource() -> AggregateCandidateSource { AggregateCandidateSource([]) }
}
