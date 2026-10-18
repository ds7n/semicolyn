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
    /// Exclusion rules: applied at write time by `record` and `harvest`, and
    /// re-applied at read time by every suggestion query as a safety net.
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
    /// Shipped English dictionary for the single ranker; `nil` under the legacy init.
    private let english: WordDictionary?
    /// Shipped command tree for the single ranker; `nil` under the legacy init.
    private let commands: CommandTree?
    /// Single-ranker weights (unused by the legacy query API).
    public var weights: RankingWeights

    public init(learned: LearnedState, seed: PredictorSeed?,
                proseSeed: PredictorSeed? = nil,
                filter: TokenFilter = .init(), config: SuggestionConfig = .init(),
                window: RollingWindow = .days30) {
        self.learned = learned
        self.seed = seed
        self.proseSeed = proseSeed
        self.cliMagnitude = seed.map { Double($0.unigram.magnitude()) } ?? 0
        self.proseMagnitude = proseSeed.map { Double($0.unigram.magnitude()) } ?? 0
        self.output = OutputHarvest(capacity: 512)
        self.filter = filter
        self.config = config
        self.window = window
        self.english = nil
        self.commands = nil
        self.weights = RankingWeights()
    }

    /// An engine for the single ranker (``suggestions(line:lineOptedOut:limit:)``),
    /// reading the shipped English dictionary and command tree. Either may be `nil`
    /// (that source then adds nothing). The legacy seeds are absent, so the legacy
    /// query API returns learned and harvested words only.
    public init(learned: LearnedState, english: WordDictionary?, commands: CommandTree?,
                filter: TokenFilter = .init(), weights: RankingWeights = .init(),
                window: RollingWindow = .days30) {
        self.learned = learned
        self.seed = nil
        self.proseSeed = nil
        self.cliMagnitude = 0
        self.proseMagnitude = 0
        self.output = OutputHarvest(capacity: 512)
        self.filter = filter
        self.config = SuggestionConfig()
        self.window = window
        self.english = english
        self.commands = commands
        self.weights = weights
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
    /// Normalization: the learned form is `lookupWord(fromToken: token).word` (a
    /// token that is only punctuation is not recorded), and the bigram is keyed on
    /// the previous token's lookup word lowercased, the key every bigram read uses.
    ///
    /// L6: tokens are deferred until they recur across N distinct contexts; see
    /// ``GraduationTier``.
    ///
    /// L7: `echoConfirmed` and `optedOut` thread through to ``LearnConfidence``.
    /// A token with `.low` confidence graduates count-only (no stored literal) so it
    /// never surfaces as a completion, the core secret-exclusion invariant.
    public mutating func record(_ token: String, count: UInt32 = 1, after previous: String? = nil,
                                echoConfirmed: Bool = true, optedOut: Bool = false) {
        // Normalize: learn the lookup word (surrounding punctuation trimmed; paths and
        // flags whole). Both the raw token and the word must pass the filter, so
        // trimming can never let an excluded form through.
        guard !filter.excludes(token) else { return }
        let word = lookupWord(fromToken: token).word
        guard !word.isEmpty, !filter.excludes(word) else { return }
        // L7: derive graduation confidence from all visible layers. High iff the
        // echo oracle confirmed the character, the line was not marked opted-out,
        // and neither form is in the soft entropy band (L5 near-miss).
        let nearMiss = filter.isPatternAdjacent(token) || filter.isPatternAdjacent(word)
        let confidence: LearnConfidence = (echoConfirmed && !optedOut && !nearMiss) ? .high : .low
        // L6: defer until the token has recurred across N distinct contexts. `admit`
        // returns the occurrences to persist now (empty while deferred; the full
        // backfill on graduation; just this one once already graduated).
        let context = previous.flatMap(bigramContext(forPrevious:))
        for occ in graduation.admit(token: word, previous: context, count: count, confidence: confidence) {
            let storeLiteral = (occ.confidence == .high)
            learned.unigram.record(occ.token, count: occ.count, storeLiteral: storeLiteral)
            if let prev = occ.previous, !filter.excludes(prev) {
                learned.bigram.record(previous: prev, next: occ.token, count: occ.count,
                                      storeLiteral: storeLiteral)
            }
        }
    }

    /// The graduation context and bigram key for a raw previous token: its lookup word
    /// folded to lowercase (the one key convention every bigram read uses), or `nil`
    /// when nothing word-like is left (treated as start of line). When the raw token
    /// or its lookup word is excluded, that excluded form is returned instead, so the
    /// context still counts toward graduation but the write-time `filter.excludes(prev)`
    /// gate drops the adjacency (folding can lower entropy, so only an already-excluded
    /// form is safe to carry). A folded key that is itself excluded is dropped by the
    /// same gate.
    private func bigramContext(forPrevious raw: String) -> String? {
        if filter.excludes(raw) { return raw }
        let word = lookupWord(fromToken: raw).word
        guard !word.isEmpty else { return nil }
        if filter.excludes(word) { return word }
        return word.lowercased()
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

    /// Harvest screen words from command `output` so they surface as completions.
    /// Escapes are stripped, then each whitespace-delimited token is kept only if
    /// it is screen-word shaped (``isScreenWordShaped(_:)``), passes the privacy
    /// `filter`, and is not the value of a secret flag (the preceding token, kept
    /// or not, is the context). Rejected tokens are harvested nowhere.
    public mutating func harvest(output: String) {
        let raw = stripANSI(output)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        var kept: [String] = []
        var previous: String?
        for token in raw {
            defer { previous = token }
            guard isScreenWordShaped(token), !filter.excludes(token),
                  !isSecretValueToken(token, precededBy: previous) else { continue }
            kept.append(token)
        }
        self.output.harvest(kept)
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
        scoredMerged(prefix: prefix, previous: previous, context: context)
            .prefix(config.topK)
            .map { $0.token }
    }

    /// The shared core of `suggestions(forPrefix:after:context:)`: source
    /// construction (unigram vs bigram axis), the `DualSeedSuggester` fill-path
    /// query, and the harvest-leads + `filter.excludes` + dedup merge, but
    /// returning `(token, score)` pairs instead of collapsing to `[String]`, so a
    /// caller (`blendedSuggestions`) can rank this axis's results against another
    /// axis's by score. Harvested tokens (already newest-first, ephemeral output)
    /// must keep leading the merge exactly as `suggestions` does today; they are
    /// given a synthetic score strictly above the highest seed/learned score,
    /// descending by recency, so they also sort first when blended against another
    /// `scoredMerged` call's results.
    ///
    /// Callers that only need the final token order and count (`suggestions`)
    /// truncate this result to `config.topK`; this helper itself does not cap so a
    /// blend can compare a fuller ranked list from each axis before capping once at
    /// the end.
    private func scoredMerged(prefix: String, previous: String?,
                              context: PredictionContext) -> [(token: String, score: Double)] {
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
            // `record` keys learned bigrams on the folded previous word.
            learnedSource = learned.bigram.nextSource(after: previous.lowercased(), window: window)
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
            .scoredSuggestions(forPrefix: prefix, limit: overfetchLimit)

        // Harvested output leads (already newest-first); learned/seed fill the rest.
        // Harvested tokens carry no natural score of their own (they are not ranked
        // by count), so synthesize one strictly above every seed/learned score here,
        // descending by harvest recency, which reproduces "harvested leads" both in
        // this axis's own order and when blended against another axis's scores.
        //
        // Only apply harvest when `prefix` is non-empty. `OutputHarvest` is a pure
        // completion-oriented (prefix) store with no bigram/"followed by" concept;
        // on an empty prefix (the next-word axis, querying `previous`'s successors)
        // `candidates(forPrefix: "")` would match every harvested token as a bogus
        // successor of `previous`, which is wrong.
        let harvestedTokens = prefix.isEmpty ? [] : output.candidates(forPrefix: prefix).map { $0.token }
        let maxSeedScore = base.map { $0.score }.max() ?? 0
        let harvested: [(token: String, score: Double)] = harvestedTokens.enumerated().map { index, token in
            (token: token, score: maxSeedScore + 1 + Double(harvestedTokens.count - index))
        }

        var seen = Set<String>()
        var merged: [(token: String, score: Double)] = []
        for entry in harvested + base {
            if filter.excludes(entry.token) { continue }
            guard seen.insert(entry.token).inserted else { continue }
            merged.append(entry)
        }
        return merged
    }

    /// Up to `limit` ranked suggestions for the token at the end of `line`, from one
    /// comparable score over the English dictionary, command tree, learned words,
    /// screen words, bigram context and spelling corrections. `filter` is re-applied
    /// at read time. No minimum prefix: one letter gets suggestions. Returns `[]` when
    /// the cursor follows trailing punctuation. With no word being typed it predicts the
    /// next word; after a finished word it adds lower-weight next-word chips.
    /// `lineOptedOut` suppresses every next-word chip; completions stay allowed on an
    /// opted-out line, as in the legacy path.
    public func suggestions(line: String, lineOptedOut: Bool, limit: Int = 12) -> [Suggestion] {
        let sources = RankingSources(
            english: english, commands: commands, learned: learned, screen: output,
            filter: filter, weights: weights, window: window)
        return rankSuggestions(line: line, lineOptedOut: lineOptedOut, sources: sources, limit: limit)
    }

    /// One chip in a ``blendedSuggestions`` result: either a completion of the
    /// currently-typed word (`isNextWord == false`) or a predicted word to follow
    /// it (`isNextWord == true`). The App uses `isNextWord` to style/insert the
    /// chip differently (e.g. inserting a leading space for a next-word chip).
    public struct BlendedChip: Equatable, Sendable {
        public let token: String
        public let isNextWord: Bool
        public init(token: String, isNextWord: Bool) { self.token = token; self.isNextWord = isNextWord }
    }

    /// Up to `config.topK` chips blending two axes for the word the user is
    /// currently typing (`current`): completions of `current` itself, and
    /// predicted words to follow it (next-word, keyed as the bigram successor of
    /// `current` with an empty prefix). Both axes go through the same
    /// `scoredMerged` core (source construction, seed fill, harvest lead, privacy
    /// filter, dedup) as `suggestions(...)`, so a blended chip is held to the same
    /// exclusion/ranking rules as a plain completion or next-word query.
    ///
    /// When only one axis has candidates, the result is that axis's ranking
    /// unchanged (capped at `topK`). When both do, the single top-ranked candidate
    /// of each axis is reserved a slot first (so a completion and a next-word
    /// always both appear when available), then the remaining candidates from both
    /// axes are merged by descending score to fill out the cap, skipping tokens
    /// already chosen. `current` itself is never suggested by either axis (it is
    /// what the user already typed, not a completion of itself).
    ///
    /// `allowNextWord` gates the next-word axis entirely: when `false` the
    /// next-word query is not run at all (a secret-value `current`, an opted-out
    /// line, or a too-short `current` must never leak a successor query), and the
    /// result is completions-only, same as the `nextWords.isEmpty` case below.
    public func blendedSuggestions(current: String, previous: String?, allowNextWord: Bool = true,
                                   context: PredictionContext = .init()) -> [BlendedChip] {
        guard !current.isEmpty else { return [] }
        // Completions of `current` (exclude the exact typed token).
        let completions = scoredMerged(prefix: current, previous: previous, context: context)
            .filter { $0.token != current }
        // Next-words keyed on `current` (empty prefix, bigram after current). Skipped
        // entirely when `allowNextWord` is false.
        let nextWords = allowNextWord
            ? scoredMerged(prefix: "", previous: current, context: context).filter { $0.token != current }
            : []
        let cap = config.topK
        if nextWords.isEmpty {
            return Array(completions.prefix(cap)).map { BlendedChip(token: $0.token, isNextWord: false) }
        }
        if completions.isEmpty {
            return Array(nextWords.prefix(cap)).map { BlendedChip(token: $0.token, isNextWord: true) }
        }
        // Both non-empty: reserve top of each, then fill remainder by score, de-duped.
        var chosen: [BlendedChip] = []
        var seen = Set<String>()
        func take(_ token: String, _ isNext: Bool) {
            guard !seen.contains(token), chosen.count < cap else { return }
            seen.insert(token); chosen.append(BlendedChip(token: token, isNextWord: isNext))
        }
        take(completions[0].token, false)
        take(nextWords[0].token, true)
        // Remainder: merge the two tails by descending score.
        let rest = (completions.dropFirst().map { ($0.token, $0.score, false) }
                  + nextWords.dropFirst().map { ($0.token, $0.score, true) })
            .sorted { $0.1 > $1.1 }
        for (token, _, isNext) in rest { take(token, isNext) }
        return chosen
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
