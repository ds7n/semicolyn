// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Raw inputs for the English dictionary build.
public struct EnglishSources: Sendable {
    /// Cased Google Books unigram counts.
    public var books: [String: UInt64]
    /// Folded wordfreq frequencies (fraction of tokens).
    public var wordfreq: [String: Double]
    /// Folded SCOWL words.
    public var realWords: Set<String>
    /// Cased single-word Wikipedia titles.
    public var titleWords: Set<String>
    /// Folded words that must never be offered.
    public var blocklist: Set<String>

    public init(books: [String: UInt64], wordfreq: [String: Double], realWords: Set<String>,
                titleWords: Set<String>, blocklist: Set<String>) {
        self.books = books
        self.wordfreq = wordfreq
        self.realWords = realWords
        self.titleWords = titleWords
        self.blocklist = blocklist
    }
}

/// Limits and thresholds for the English dictionary build.
public struct EnglishBuildConfig: Sendable {
    public var maxWords = 150_000
    public var successorWords = 40_000
    public var successorsPerWord = 24
    public var minZipf = 3.0

    public init() {}
}

/// Picks the case forms worth storing from all cased variants of ONE folded word.
///
/// A variant is kept at >= 25% of the group total, or >= 50% when its only uppercase letter
/// is the first (sentence-start capitals inflate those). Dropped counts go to the kept
/// variant with the largest count. If nothing qualifies the largest variant takes the total.
public func selectCaseForms(_ cased: [String: UInt64]) -> [String: UInt64] {
    var total: UInt64 = 0
    for count in cased.values { total = total &+ count }
    guard total > 0 else { return [:] }

    // share >= 1/d  <=>  count >= ceil(total / d)
    let quarter = total / 4 + (total % 4 == 0 ? 0 : 1)
    let half = total / 2 + (total % 2 == 0 ? 0 : 1)

    func isLargerFirst(_ a: (key: String, value: UInt64), _ b: (key: String, value: UInt64)) -> Bool {
        a.value != b.value ? a.value > b.value : a.key < b.key
    }

    var kept: [String: UInt64] = [:]
    for (form, count) in cased {
        let needed = hasOnlyLeadingCapital(form) ? half : quarter
        if count >= needed { kept[form] = count }
    }
    let nothingQualified = kept.isEmpty
    guard let top = (nothingQualified ? cased : kept).sorted(by: isLargerFirst).first else { return [:] }

    let keptSum = nothingQualified ? top.value : kept.values.reduce(0 as UInt64) { $0 &+ $1 }
    kept[top.key] = top.value &+ (total &- keptSum)
    return kept
}

private func hasOnlyLeadingCapital(_ form: String) -> Bool {
    guard let first = form.first, first.isUppercase else { return false }
    return !form.dropFirst().contains(where: { $0.isUppercase })
}

/// Builds the scored word list: case-form selection, admission rules, merged frequency,
/// top `maxWords`, then log-scaled 1...255 score bytes. Ordered by score desc, then text.
public func buildEnglishEntries(_ sources: EnglishSources, config: EnglishBuildConfig) -> [ScoredWord] {
    var groups: [String: [String: UInt64]] = [:]
    var booksTotal: Double = 0
    for (form, count) in sources.books where count > 0 {
        groups[form.lowercased(), default: [:]][form, default: 0] += count
        booksTotal += Double(count)
    }
    var folds = Set(groups.keys)
    for word in sources.wordfreq.keys where groups[word] == nil { folds.insert(word) }

    var candidates: [(text: String, f: Double)] = []
    for fold in folds {
        guard !fold.isEmpty, !sources.blocklist.contains(fold) else { continue }
        let freq = sources.wordfreq[fold].flatMap { $0 > 0 ? $0 : nil }
        let zipfOK = freq.map { log10($0) + 9 >= config.minZipf } ?? false
        let realOK = sources.realWords.contains(fold)

        let forms: [(text: String, count: UInt64?, share: Double)]
        if let group = groups[fold] {
            let groupTotal = Double(group.values.reduce(0 as UInt64) { $0 &+ $1 })
            forms = selectCaseForms(group).map { ($0.key, $0.value, Double($0.value) / groupTotal) }
        } else {
            forms = [(fold, nil, 1)]
        }
        for form in forms {
            guard form.text.utf8.count <= 255 else { continue }
            let titleOK = form.count != nil && sources.titleWords.contains(form.text)
            guard realOK || zipfOK || titleOK else { continue }
            let fb = form.count.map { Double($0) / booksTotal }
            let fw = freq.map { $0 * form.share }
            let f: Double
            switch (fb, fw) {
            case let (b?, w?): f = (b * w).squareRoot()
            case let (b?, nil): f = 0.5 * b
            case let (nil, w?): f = 0.5 * w
            case (nil, nil): continue
            }
            guard f > 0, f.isFinite else { continue }
            candidates.append((form.text, f))
        }
    }

    candidates.sort { $0.f != $1.f ? $0.f > $1.f : $0.text < $1.text }
    let top = Array(candidates.prefix(max(0, config.maxWords)))
    guard let fMax = top.first?.f, let fMin = top.last?.f else { return [] }
    let span = log(fMax) - log(fMin)
    let scored = top.map { c -> ScoredWord in
        guard span > 0 else { return ScoredWord(text: c.text, score: 255) }
        let scaled = 254 * (log(c.f) - log(fMin)) / span
        return ScoredWord(text: c.text, score: UInt8(min(255, 1 + scaled.rounded())))
    }
    return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
}

/// Maps words to dense ids so bigram counts can be accumulated without per-pair strings.
///
/// Previous words are folded and limited to the `successorWords` most frequent folded
/// words (by best score); next words resolve to the highest-scoring kept stored form of
/// their fold. A pair packs as `prevId << 32 | nextId` (`nextId` indexes `entries`).
public struct SuccessorIndex: Sendable {
    private let entries: [ScoredWord]
    private let prevIds: [String: UInt32]
    private let prevWords: [String]
    private let nextIds: [String: UInt32]

    public init(entries: [ScoredWord], config: EnglishBuildConfig) {
        self.entries = entries
        var bestForFold: [String: (index: Int, score: UInt8)] = [:]
        for (index, entry) in entries.enumerated() {
            let fold = entry.text.lowercased()
            if let current = bestForFold[fold],
               current.score > entry.score || (current.score == entry.score && entries[current.index].text < entry.text) {
                continue
            }
            bestForFold[fold] = (index, entry.score)
        }
        var next: [String: UInt32] = [:]
        for (fold, best) in bestForFold { next[fold] = UInt32(best.index) }
        nextIds = next

        let ranked = bestForFold.sorted { a, b in
            a.value.score != b.value.score ? a.value.score > b.value.score : a.key < b.key
        }.prefix(max(0, config.successorWords)).map(\.key)
        prevWords = ranked
        var prev: [String: UInt32] = [:]
        for (id, word) in ranked.enumerated() { prev[word] = UInt32(id) }
        prevIds = prev
    }

    /// Packs a (previous, next) pair, or nil when either word is not eligible.
    public func pack(prev: String, next: String) -> UInt64? {
        guard let p = prevIds[prev.lowercased()], let n = nextIds[next.lowercased()] else { return nil }
        return UInt64(p) << 32 | UInt64(n)
    }

    /// Builds the top successors per previous word from packed pair counts.
    public func successors(from packed: [UInt64: UInt64], config: EnglishBuildConfig) -> [String: [ScoredWord]] {
        var byPrev: [UInt32: [(next: UInt32, count: UInt64)]] = [:]
        for (key, count) in packed {
            byPrev[UInt32(key >> 32), default: []].append((UInt32(key & 0xFFFF_FFFF), count))
        }
        var result: [String: [ScoredWord]] = [:]
        for (prevId, list) in byPrev {
            let ranked = list.sorted { a, b in
                a.count != b.count ? a.count > b.count : entries[Int(a.next)].text < entries[Int(b.next)].text
            }.prefix(max(0, config.successorsPerWord))
            guard let topCount = ranked.first?.count, topCount > 0 else { continue }
            result[prevWords[Int(prevId)]] = ranked.map { item in
                let scaled = 254 * Double(item.count) / Double(topCount)
                return ScoredWord(text: entries[Int(item.next)].text, score: UInt8(min(255, 1 + scaled.rounded())))
            }
        }
        return result
    }
}

/// Builds folded-key successor lists from string pairs. See ``SuccessorIndex`` for the rules;
/// case-variant pairs are merged by summing, and pairs whose next word has no kept form are dropped.
public func buildSuccessors(pairs: [(prev: String, next: String, count: UInt64)], entries: [ScoredWord],
                            config: EnglishBuildConfig) -> [String: [ScoredWord]] {
    let index = SuccessorIndex(entries: entries, config: config)
    var packed: [UInt64: UInt64] = [:]
    for pair in pairs {
        guard let key = index.pack(prev: pair.prev, next: pair.next) else { continue }
        packed[key, default: 0] = packed[key, default: 0] &+ pair.count
    }
    return index.successors(from: packed, config: config)
}
