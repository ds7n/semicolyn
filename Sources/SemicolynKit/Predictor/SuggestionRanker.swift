// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One ranked chip for the predictor strip.
public struct Suggestion: Equatable, Sendable {
    /// What accepting the chip means.
    public enum Kind: Equatable, Sendable {
        /// Completes the word being typed.
        case completion
        /// A word to follow the last completed word.
        case nextWord
        /// A spelling fix for the word being typed (never applied automatically).
        case correction
    }

    public let text: String
    public let kind: Kind
    /// Comparable across sources; higher ranks first.
    public let score: Double

    public init(text: String, kind: Kind, score: Double) {
        self.text = text
        self.kind = kind
        self.score = score
    }
}

/// The tunable weights of the single ranker. Every source term is normalized to
/// roughly `0...1` before its weight applies, so the weights alone set how sources
/// compare.
public struct RankingWeights: Equatable, Sendable {
    /// English dictionary weight on prose and undecided lines.
    public var english: Double = 1.0
    /// English dictionary weight on a command line.
    public var englishInCommand: Double = 0.5
    /// Command tree weight (not used on prose lines).
    public var commands: Double = 1.0
    /// Learned count at which the learned term reaches its maximum of 1.
    public var learnedSaturation: UInt32 = 64
    /// Weight of the newest screen word; older ones decay linearly.
    public var screen: Double = 0.6
    /// Spelling-correction weight.
    public var correction: Double = 0.7
    /// Next-word weight (used by next-word mode).
    public var nextWord: Double = 0.9
    /// Next-word weight after a plain word (used by next-word mode).
    public var nextWordAfterWord: Double = 0.45
    /// Bigram-context bonus weight for a completion that follows the previous word.
    public var context: Double = 0.5

    public init() {}
}

/// The read-only sources one ranking pass consults, snapshotted from the engine.
struct RankingSources {
    let english: WordDictionary?
    let commands: CommandTree?
    let learned: LearnedState
    let screen: OutputHarvest
    let filter: TokenFilter
    let weights: RankingWeights
    let window: RollingWindow
}

/// `min(1, log2(1 + count) / log2(1 + saturation))`: the learned-count term, rising
/// quickly for the first few uses and capping at 1. A zero saturation is treated as 1.
func learnedTerm(count: UInt32, saturation: UInt32) -> Double {
    let cap = log2(1 + Double(max(1, saturation)))
    return min(1, log2(1 + Double(count)) / cap)
}

/// Ranked suggestions for the token at the end of `line`. Returns `[]` when the
/// cursor sits after trailing punctuation or when `limit <= 0`.
///
/// With no word being typed this is next-word mode (``nextWordSuggestions``). With a
/// word typed it is completion mode, plus next-word candidates for that word at the
/// lower `nextWordAfterWord` weight when it is a finished word (an English word, a
/// known tool or a learned literal). `lineOptedOut` suppresses every next-word
/// candidate; completions stay allowed. All kinds sort together by score.
func rankSuggestions(line: String, lineOptedOut: Bool, sources: RankingSources, limit: Int) -> [Suggestion] {
    guard limit > 0 else { return [] }
    let isKnownTool: (String) -> Bool = { word in sources.commands?.isKnownTool(word) ?? false }
    let ctx = lineContext(line: line, isKnownTool: isKnownTool)
    let lw = lookupWord(fromToken: ctx.currentToken)
    guard lw.trailing.isEmpty else { return [] }
    let typed = lw.word

    var ranked: [Suggestion]
    if typed.isEmpty {
        guard !lineOptedOut else { return [] }
        ranked = nextWordSuggestions(ctx: ctx, weight: sources.weights.nextWord, sources: sources)
    } else {
        ranked = completionSuggestions(typed: typed, ctx: ctx, sources: sources)
        if !lineOptedOut, isFinishedWord(typed, sources: sources) {
            // The context the next word would be typed in: the same line after a space.
            let nextCtx = lineContext(line: line + " ", isKnownTool: isKnownTool)
            let taken = Set(ranked.map(\.text))
            let next = nextWordSuggestions(ctx: nextCtx, weight: sources.weights.nextWordAfterWord, sources: sources)
            // A text already offered as a completion or correction keeps that chip only.
            ranked += next.filter { !taken.contains($0.text) }
        }
    }
    ranked.sort { a, b in
        a.score != b.score ? a.score > b.score : a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
    }
    return Array(ranked.prefix(limit))
}

/// True when `typed` is a whole word worth predicting a successor for: an English
/// word (any stored case), a known tool, or a learned literal (as typed or lowercased).
private func isFinishedWord(_ typed: String, sources: RankingSources) -> Bool {
    if sources.english?.bestStoredForm(ofFolded: typed) != nil { return true }
    if sources.commands?.isKnownTool(typed) ?? false { return true }
    let unigram = sources.learned.unigram
    return unigram.containsLiteral(typed) || unigram.containsLiteral(typed.lowercased())
}

/// Next-word candidates for the empty token after `ctx`, scored with `weight` in
/// place of a per-source weight: command-tree candidates on non-prose lines
/// (`weight * s/255`), English successors of the previous word (`weight * s/255`,
/// halved by `englishInCommand` on a command line) and learned bigram successors
/// of the folded previous word (`weight * learnedTerm`), summed per text.
///
/// Returns `[]` at the start of an empty line or segment (no previous word, no
/// segment words, not after a pipe) and when the next token would be a secret
/// value (the previous word is a secret flag or header). `filter` is re-applied.
private func nextWordSuggestions(ctx: LineContext, weight: Double, sources: RankingSources) -> [Suggestion] {
    guard ctx.previousWord != nil || !ctx.segmentWords.isEmpty || ctx.afterPipe else { return [] }
    guard !isSecretValueToken("", precededBy: ctx.previousWord) else { return [] }
    let w = sources.weights
    var scores: [String: Double] = [:]

    if ctx.kind != .prose, let commands = sources.commands {
        let found = commands.candidates(
            segmentWords: ctx.segmentWords, typed: "", afterPipe: ctx.afterPipe, limit: 20)
        for word in found {
            scores[word.text, default: 0] += weight * (Double(word.score) / 255)
        }
    }
    if let previous = ctx.previousWord, !previous.isEmpty {
        if let english = sources.english {
            let kindWeight = ctx.kind == .command ? w.englishInCommand : w.english
            for next in english.successors(of: previous, limit: 20) {
                scores[next.text, default: 0] += weight * (Double(next.score) / 255) * kindWeight
            }
        }
        // `record` keys bigrams on the folded previous word; read the same key.
        var best: [String: UInt32] = [:]
        for entry in sources.learned.bigram.candidates(after: previous.lowercased(), window: sources.window)
        where entry.count > 0 {
            best[entry.token] = max(best[entry.token] ?? 0, entry.count)
        }
        for (text, count) in best {
            scores[text, default: 0] += weight * learnedTerm(count: count, saturation: w.learnedSaturation)
        }
    }
    return scores.compactMap { text, score in
        sources.filter.excludes(text) ? nil : Suggestion(text: text, kind: .nextWord, score: score)
    }
}

/// Completion-mode chips for `typed`: summed completion terms (minus the exact typed
/// word) and spelling corrections, read-time filtered, unsorted.
private func completionSuggestions(typed: String, ctx: LineContext, sources: RankingSources) -> [Suggestion] {
    var scores = completionScores(typed: typed, ctx: ctx, sources: sources)
    scores[typed] = nil
    var ranked: [Suggestion] = scores.compactMap { text, score in
        sources.filter.excludes(text) ? nil : Suggestion(text: text, kind: .completion, score: score)
    }
    if let english = sources.english {
        for fix in spellingCorrections(for: typed, in: english, limit: 2) {
            guard scores[fix.text] == nil, fix.text != typed, !sources.filter.excludes(fix.text) else { continue }
            let score = sources.weights.correction * Double(fix.score) / 255
            ranked.append(Suggestion(text: fix.text, kind: .correction, score: score))
        }
    }
    return ranked
}

/// Summed completion terms per display text, before the exact-typed drop and filter.
private func completionScores(typed: String, ctx: LineContext, sources: RankingSources) -> [String: Double] {
    let w = sources.weights
    var scores: [String: Double] = [:]

    if let english = sources.english {
        let weight = ctx.kind == .command ? w.englishInCommand : w.english
        for word in english.completions(typed: typed, limit: 40) {
            scores[word.text, default: 0] += Double(word.score) / 255 * weight
        }
    }
    if ctx.kind != .prose, let commands = sources.commands {
        let found = commands.candidates(
            segmentWords: ctx.segmentWords, typed: typed, afterPipe: ctx.afterPipe, limit: 20)
        for word in found {
            scores[word.text, default: 0] += Double(word.score) / 255 * w.commands
        }
    }
    let learnedSource = sources.learned.unigram.learnedSource(window: sources.window)
    for (text, count) in learnedMatches(typed: typed, source: learnedSource) {
        scores[text, default: 0] += learnedTerm(count: count, saturation: w.learnedSaturation)
    }
    for (text, term) in screenTerms(typed: typed, pool: sources.screen, weight: w.screen) {
        scores[text, default: 0] += term
    }
    if let previous = ctx.previousWord, !previous.isEmpty {
        addContext(previous: previous, typed: typed, sources: sources, to: &scores)
    }
    return scores
}

/// Learned tokens that case-match `typed`, keyed by display text (the highest count
/// wins when two stored forms display alike). The prefix index is byte-exact, so it
/// is probed with the first typed character in each case and then narrowed with
/// ``caseMatchedForm(typed:candidate:)``; probing the whole typed prefix would miss
/// mixed-case words such as `GitHub` for `gith`. Tokens with a zero count in the
/// window (aged out) are skipped.
private func learnedMatches(typed: String, source: any CandidateSource) -> [String: UInt32] {
    guard let first = typed.first else { return [:] }
    let lead = String(first)
    var probes: [String] = []
    for probe in [lead, lead.lowercased(), lead.uppercased()] where !probes.contains(probe) {
        probes.append(probe)
    }
    var out: [String: UInt32] = [:]
    for probe in probes {
        // An indexed token outside the window estimates 0: it is not a learned word now.
        for entry in source.candidates(forPrefix: probe) where entry.count > 0 {
            guard let display = caseMatchedForm(typed: typed, candidate: entry.token) else { continue }
            out[display] = max(out[display] ?? 0, entry.count)
        }
    }
    return out
}

/// Screen-pool words that case-match `typed`, scored `weight * (1 - rankIndex / poolCount)`
/// where `rankIndex` is the word's position in the whole pool, newest first.
private func screenTerms(typed: String, pool: OutputHarvest, weight: Double) -> [String: Double] {
    let all = pool.candidates(forPrefix: "")
    guard !all.isEmpty else { return [:] }
    let poolCount = Double(all.count)
    var out: [String: Double] = [:]
    for (rankIndex, entry) in all.enumerated() {
        guard let display = caseMatchedForm(typed: typed, candidate: entry.token) else { continue }
        let term = weight * (1 - Double(rankIndex) / poolCount)
        out[display] = max(out[display] ?? 0, term)
    }
    return out
}

/// Adds the bigram-context bonus to candidates already in `scores` that are known
/// successors of `previous` (English successor table and learned bigrams).
private func addContext(previous: String, typed: String, sources: RankingSources, to scores: inout [String: Double]) {
    let w = sources.weights
    if let english = sources.english {
        for next in english.successors(of: previous, limit: 64) {
            guard let display = caseMatchedForm(typed: typed, candidate: next.text), scores[display] != nil else {
                continue
            }
            scores[display, default: 0] += w.context * Double(next.score) / 255
        }
    }
    let learnedNext = sources.learned.bigram.candidates(after: previous.lowercased(), window: sources.window)
    var best: [String: UInt32] = [:]
    for entry in learnedNext where entry.count > 0 {
        guard let display = caseMatchedForm(typed: typed, candidate: entry.token), scores[display] != nil else {
            continue
        }
        best[display] = max(best[display] ?? 0, entry.count)
    }
    for (display, count) in best {
        scores[display, default: 0] += w.context * learnedTerm(count: count, saturation: w.learnedSaturation)
    }
}
