// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The runtime facade: one type the app records into and queries for suggestions,
/// composing the write-time privacy filter, the learned windowed stores, the shipped
/// English dictionary and command tree, and the single ranker. Holds no I/O: the app
/// loads its inputs (``LearnedStore``, the bundled dictionaries) and flushes `state`
/// back. See `2026-06-21-predictor-engine-design`.
public struct PredictorEngine: Sendable {
    private var learned: LearnedState
    /// Ephemeral output-token context (not persisted); screen words for the ranker.
    private var output: OutputHarvest
    /// Harvest context carried across `harvest(output:)` chunks: escape-filter state,
    /// the last complete token (for the secret-flag check) and an unfinished
    /// trailing token (UTF-8) joined with the start of the next chunk.
    private var harvestFilter = ANSIByteFilter()
    private var harvestPrevious: String?
    private var harvestPartial: [UInt8] = []
    /// Exclusion rules: applied at write time by `record` and `harvest`, and
    /// re-applied at read time by every suggestion query as a safety net.
    public var filter: TokenFilter
    /// Which rolling pre-aggregate suggestions read.
    public var window: RollingWindow
    /// Shipped English dictionary; `nil` adds nothing.
    private let english: WordDictionary?
    /// Shipped command tree; `nil` adds nothing.
    private let commands: CommandTree?
    /// Single-ranker weights.
    public var weights: RankingWeights

    /// An engine for the single ranker (``suggestions(line:lineOptedOut:limit:)``),
    /// reading the shipped English dictionary and command tree. Either may be `nil`
    /// (that source then adds nothing).
    public init(learned: LearnedState, english: WordDictionary?, commands: CommandTree?,
                filter: TokenFilter = .init(), weights: RankingWeights = .init(),
                window: RollingWindow = .days30) {
        self.learned = learned
        self.output = OutputHarvest(capacity: 512)
        self.filter = filter
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
    /// as a safety net, since a bundled dictionary (unlike `record`) can carry an
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
                                echoConfirmed: Bool = true, optedOut: Bool = false,
                                accepted: Bool = false) {
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
        let required = requiredContexts(forWord: word, accepted: accepted)
        for occ in graduation.admit(token: word, previous: context, count: count, confidence: confidence,
                                    requiredContexts: required) {
            let storeLiteral = (occ.confidence == .high)
            learned.unigram.record(occ.token, count: occ.count, storeLiteral: storeLiteral)
            if let prev = occ.previous, !filter.excludes(prev) {
                learned.bigram.record(previous: prev, next: occ.token, count: occ.count,
                                      storeLiteral: storeLiteral)
            }
        }
    }

    /// Distinct contexts a word needs before it graduates: 1 when the user tapped it
    /// or it was already learned in an earlier session, 2 for a dictionary word or
    /// known tool, otherwise the tier default (nil = 3). Only speed changes: the
    /// token filter and the confidence rule still gate what is stored.
    private func requiredContexts(forWord word: String, accepted: Bool) -> Int? {
        if accepted || learned.unigram.containsLiteral(word) { return 1 }
        if english?.bestStoredForm(ofFolded: word.lowercased()) != nil { return 2 }
        if commands?.isKnownTool(word) == true { return 2 }
        return nil
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
    /// + L6 tier). The bundled dictionaries are `let`s and are untouched. Panic-purge's Kit half.
    public mutating func purgeLearned() {
        learned = .empty
        output.clear()
        resetHarvestContext()
        graduation.reset()
    }

    /// Harvest screen words from command `output` so they surface as completions.
    /// Chunk-safe: escape sequences, the secret-flag context and a token not yet
    /// ended by whitespace all carry into the next call. A kept token is
    /// screen-word shaped (``isScreenWordShaped(_:)``), passes the privacy
    /// `filter`, and is not the value of a secret flag. Rejected tokens are
    /// harvested nowhere.
    public mutating func harvest(output: String) {
        let clean = harvestFilter.filter(Array(output.utf8))
        let bytes = harvestPartial + clean
        harvestPartial = []
        var tokens: [[UInt8]] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d {
                if !current.isEmpty { tokens.append(current); current = [] }
            } else {
                current.append(b)
            }
        }
        // An unfinished trailing token waits for the next chunk. Over 65 bytes it
        // can never be shape-valid, so only a prefix is kept (bounded memory).
        harvestPartial = Array(current.prefix(65))
        var kept: [String] = []
        for raw in tokens {
            let token = String(decoding: raw, as: UTF8.self)
            defer { harvestPrevious = token }
            guard isScreenWordShaped(token), !filter.excludes(token),
                  !isSecretValueToken(token, precededBy: harvestPrevious) else { continue }
            kept.append(token)
        }
        self.output.harvest(kept)
    }

    private mutating func resetHarvestContext() {
        harvestFilter = ANSIByteFilter()
        harvestPrevious = nil
        harvestPartial = []
    }

    /// Drop harvested output tokens, for a context change (host switch, incognito).
    public mutating func clearHarvest() {
        output.clear()
        resetHarvestContext()
    }

    /// Up to `limit` ranked suggestions for the token at the end of `line`, from one
    /// comparable score over the English dictionary, command tree, learned words,
    /// screen words, bigram context and spelling corrections. `filter` is re-applied
    /// at read time. No minimum prefix: one letter gets suggestions. Returns `[]` when
    /// the cursor follows trailing punctuation. With no word being typed it predicts the
    /// next word; after a finished word it adds lower-weight next-word chips.
    /// `lineOptedOut` suppresses every next-word chip; completions stay allowed on an
    /// opted-out line.
    public func suggestions(line: String, lineOptedOut: Bool, limit: Int = 12) -> [Suggestion] {
        let sources = RankingSources(
            english: english, commands: commands, learned: learned, screen: output,
            filter: filter, weights: weights, window: window)
        return rankSuggestions(line: line, lineOptedOut: lineOptedOut, sources: sources, limit: limit)
    }

    /// Seal the day for both learned axes, the app calls this at user-local
    /// midnight.
    public mutating func rollover() {
        learned.unigram.rollover()
        learned.bigram.rollover()
    }
}
