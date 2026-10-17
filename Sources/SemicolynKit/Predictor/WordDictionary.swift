// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A dictionary word (or successor) with its 1...255 frequency score.
public struct ScoredWord: Equatable, Sendable {
    public let text: String
    public let score: UInt8

    public init(text: String, score: UInt8) {
        self.text = text
        self.score = score
    }
}

/// Why a `WordDictionary` could not be built.
public enum WordDictionaryError: Error, Equatable {
    case duplicateWord(String)
    case wordTooLong(String)
    case emptyWord
    case unknownSuccessorWord(String)
    case zeroScore(String)
}

/// The shipped English dictionary: case-aware prefix completions and folded
/// next-word successors, serialized as the `GDIC` v1 binary format.
///
/// Layout (little-endian): `47 44 49 43 | version u8 = 1 | wordCount u32`, then
/// words sorted by (folded UTF-8, stored UTF-8) as `len u8 | bytes | score u8`,
/// then `keyCount u32` and per key `wordIndex u32 | n u8 | n x (succIndex u32 | score u8)`.
/// A key's `wordIndex` is the first entry with that fold.
public struct WordDictionary: Sendable {
    private static let magic: [UInt8] = [0x47, 0x44, 0x49, 0x43]
    private static let version: UInt8 = 1

    /// Entries sorted by (folded bytes, stored bytes).
    private let words: [ScoredWord]
    /// Folded UTF-8 bytes, parallel to `words`.
    private let folded: [[UInt8]]
    /// Folded previous word -> successors, ordered by score desc then text bytes asc.
    private let successorTable: [String: [ScoredWord]]

    public var wordCount: Int { words.count }

    /// Builds a dictionary. Successor keys are folded previous words that must be
    /// present (by fold) in `entries`; successor values must name entries exactly.
    /// At most 255 successors are kept per key (the best by score).
    public init(entries: [ScoredWord], successors: [String: [ScoredWord]]) throws {
        var seen = Set<String>()
        var keyed: [(fold: [UInt8], stored: [UInt8], word: ScoredWord)] = []
        keyed.reserveCapacity(entries.count)
        for e in entries {
            if e.text.isEmpty { throw WordDictionaryError.emptyWord }
            let stored = Array(e.text.utf8)
            if stored.count > 255 { throw WordDictionaryError.wordTooLong(e.text) }
            if e.score == 0 { throw WordDictionaryError.zeroScore(e.text) }
            if !seen.insert(e.text).inserted { throw WordDictionaryError.duplicateWord(e.text) }
            keyed.append((Array(e.text.lowercased().utf8), stored, e))
        }
        keyed.sort { a, b in
            a.fold == b.fold ? a.stored.lexicographicallyPrecedes(b.stored) : a.fold.lexicographicallyPrecedes(b.fold)
        }
        let foldSet = Set(keyed.map(\.fold))
        var table: [String: [ScoredWord]] = [:]
        for (key, list) in successors {
            guard foldSet.contains(Array(key.utf8)) else {
                throw WordDictionaryError.unknownSuccessorWord(key)
            }
            var out: [ScoredWord] = []
            for s in list {
                if s.score == 0 { throw WordDictionaryError.zeroScore(s.text) }
                guard seen.contains(s.text) else { throw WordDictionaryError.unknownSuccessorWord(s.text) }
                out.append(s)
            }
            out.sort(by: WordDictionary.ranksBefore)
            table[key] = Array(out.prefix(255))
        }
        self.init(sorted: keyed.map(\.word), folded: keyed.map(\.fold), successorTable: table)
    }

    private init(sorted: [ScoredWord], folded: [[UInt8]], successorTable: [String: [ScoredWord]]) {
        self.words = sorted
        self.folded = folded
        self.successorTable = successorTable
    }

    /// Score descending, then UTF-8 bytes ascending.
    private static func ranksBefore(_ a: ScoredWord, _ b: ScoredWord) -> Bool {
        if a.score != b.score { return a.score > b.score }
        return a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
    }

    /// First index whose folded key is >= `key` (bytewise).
    private func lowerBound(_ key: [UInt8]) -> Int {
        var lo = 0
        var hi = folded.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if folded[mid].lexicographicallyPrecedes(key) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Case-matched completions of `typed`, best `limit` first. Entries that differ
    /// only by case and display identically keep the higher score.
    public func completions(typed: String, limit: Int) -> [ScoredWord] {
        guard limit > 0 else { return [] }
        let prefix = Array(typed.lowercased().utf8)
        var best: [ScoredWord] = []
        var i = lowerBound(prefix)
        while i < words.count, folded[i].starts(with: prefix) {
            // Same-fold entries are contiguous; displays can only collide within a group.
            var groupEnd = i + 1
            while groupEnd < words.count, folded[groupEnd] == folded[i] { groupEnd += 1 }
            var group: [ScoredWord] = []
            for j in i..<groupEnd {
                guard let display = caseMatchedForm(typed: typed, candidate: words[j].text) else { continue }
                let cand = ScoredWord(text: display, score: words[j].score)
                if let k = group.firstIndex(where: { $0.text == display }) {
                    if cand.score > group[k].score { group[k] = cand }
                } else {
                    group.append(cand)
                }
            }
            for cand in group { WordDictionary.insertBounded(&best, cand, limit: limit) }
            i = groupEnd
        }
        return best
    }

    /// Inserts into a rank-sorted array capped at `limit`.
    private static func insertBounded(_ best: inout [ScoredWord], _ cand: ScoredWord, limit: Int) {
        if best.count == limit, let last = best.last, !ranksBefore(cand, last) { return }
        var pos = best.count
        while pos > 0, ranksBefore(cand, best[pos - 1]) { pos -= 1 }
        best.insert(cand, at: pos)
        if best.count > limit { best.removeLast() }
    }

    /// Likely next words after `previous` (looked up case-folded), best `limit` first.
    public func successors(of previous: String, limit: Int) -> [ScoredWord] {
        guard limit > 0, let list = successorTable[previous.lowercased()] else { return [] }
        return Array(list.prefix(limit))
    }

    /// True when any stored form folds to `word.lowercased()`.
    public func containsFolded(_ word: String) -> Bool {
        score(ofFolded: word) != nil
    }

    /// The highest-scoring stored form whose fold equals `folded` (ties: UTF-8 text order), or nil.
    public func bestStoredForm(ofFolded folded: String) -> ScoredWord? {
        let key = Array(folded.lowercased().utf8)
        var i = lowerBound(key)
        var best: ScoredWord?
        // The equal-fold run is sorted by stored bytes, so a strict > keeps the earliest tie.
        while i < words.count, self.folded[i] == key {
            if best == nil || words[i].score > (best?.score ?? 0) { best = words[i] }
            i += 1
        }
        return best
    }

    /// Highest score among stored forms whose fold equals `word.lowercased()`.
    public func score(ofFolded word: String) -> UInt8? {
        let key = Array(word.lowercased().utf8)
        var i = lowerBound(key)
        var best: UInt8?
        while i < words.count, folded[i] == key {
            best = max(best ?? 0, words[i].score)
            i += 1
        }
        return best
    }

    // MARK: - Serialization

    /// Encodes the dictionary as `GDIC` v1.
    public func serialize() -> [UInt8] {
        var out = WordDictionary.magic
        out.append(WordDictionary.version)
        appendLE32(&out, UInt32(words.count))
        var indexByText: [String: Int] = [:]
        var firstByFold: [[UInt8]: Int] = [:]
        for (i, w) in words.enumerated() {
            let bytes = Array(w.text.utf8)
            out.append(UInt8(bytes.count))
            out += bytes
            out.append(w.score)
            indexByText[w.text] = i
            if firstByFold[folded[i]] == nil { firstByFold[folded[i]] = i }
        }
        let keys = successorTable.compactMap { key, list -> (Int, [ScoredWord])? in
            guard let idx = firstByFold[Array(key.utf8)] else { return nil }
            return (idx, list)
        }.sorted { $0.0 < $1.0 }
        appendLE32(&out, UInt32(keys.count))
        for (idx, list) in keys {
            appendLE32(&out, UInt32(idx))
            out.append(UInt8(list.count))
            for s in list {
                appendLE32(&out, UInt32(indexByText[s.text] ?? 0))
                out.append(s.score)
            }
        }
        return out
    }

    /// Decodes `GDIC` v1, failing closed (nil) on any structural violation.
    public init?(deserializing bytes: [UInt8]) {
        let magic = WordDictionary.magic
        guard bytes.count >= 9, Array(bytes[0..<4]) == magic, bytes[4] == WordDictionary.version,
            let count = readLE32(bytes, 5)
        else { return nil }
        var pos = 9
        var words: [ScoredWord] = []
        var folded: [[UInt8]] = []
        var storedBytes: [[UInt8]] = []
        var n: UInt32 = 0
        while n < count {
            guard pos < bytes.count else { return nil }
            let len = Int(bytes[pos])
            pos += 1
            guard len > 0, pos + len + 1 <= bytes.count else { return nil }
            let raw = Array(bytes[pos..<pos + len])
            let score = bytes[pos + len]
            pos += len + 1
            let text = String(decoding: raw, as: UTF8.self)
            guard Array(text.utf8) == raw, score != 0 else { return nil }
            let fold = Array(text.lowercased().utf8)
            if let lastFold = folded.last, let lastRaw = storedBytes.last {
                let ordered =
                    lastFold == fold
                    ? lastRaw.lexicographicallyPrecedes(raw)
                    : lastFold.lexicographicallyPrecedes(fold)
                guard ordered else { return nil }
            }
            words.append(ScoredWord(text: text, score: score))
            folded.append(fold)
            storedBytes.append(raw)
            n += 1
        }
        guard let keyCount = readLE32(bytes, pos) else { return nil }
        pos += 4
        var table: [String: [ScoredWord]] = [:]
        var lastIndex = -1
        var k: UInt32 = 0
        while k < keyCount {
            guard let rawIndex = readLE32(bytes, pos), pos + 5 <= bytes.count else { return nil }
            let wordIndex = Int(rawIndex)
            let m = Int(bytes[pos + 4])
            pos += 5
            guard wordIndex < words.count, wordIndex > lastIndex else { return nil }
            guard wordIndex == 0 || folded[wordIndex - 1] != folded[wordIndex] else { return nil }
            lastIndex = wordIndex
            var list: [ScoredWord] = []
            for _ in 0..<m {
                guard let rawSucc = readLE32(bytes, pos), pos + 5 <= bytes.count else { return nil }
                let succIndex = Int(rawSucc)
                let score = bytes[pos + 4]
                pos += 5
                guard succIndex < words.count, score != 0 else { return nil }
                list.append(ScoredWord(text: words[succIndex].text, score: score))
            }
            table[String(decoding: folded[wordIndex], as: UTF8.self)] = list
            k += 1
        }
        guard pos == bytes.count else { return nil }
        self.init(sorted: words, folded: folded, successorTable: table)
    }
}
