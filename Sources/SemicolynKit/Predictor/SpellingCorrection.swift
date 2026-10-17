// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

private let spellingAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz'")

/// Damerau edit-distance-1 variants of an already-folded word: deletes, adjacent
/// transposes, replaces and inserts over `a...z` and `'`. May contain duplicates.
private func editDistanceOneVariants(of word: [Character]) -> [String] {
    var out: [String] = []
    let n = word.count
    for i in 0..<n {
        var w = word
        w.remove(at: i)
        out.append(String(w))
    }
    if n > 1 {
        for i in 0..<(n - 1) {
            var w = word
            w.swapAt(i, i + 1)
            out.append(String(w))
        }
    }
    for i in 0..<n {
        for c in spellingAlphabet where c != word[i] {
            var w = word
            w[i] = c
            out.append(String(w))
        }
    }
    for i in 0...n {
        for c in spellingAlphabet {
            var w = word
            w.insert(c, at: i)
            out.append(String(w))
        }
    }
    return out
}

/// Spelling suggestions for `typed`: dictionary words one Damerau edit away, best
/// first (score desc, then text UTF-8 asc), capped at `limit`. Suggestions only,
/// the caller never applies them automatically. Returns `[]` when `typed` is
/// shorter than 3 characters, contains anything but letters and `'`, or is already
/// a dictionary word. A capitalized first letter in `typed` is carried over.
public func spellingCorrections(for typed: String, in dictionary: WordDictionary, limit: Int) -> [ScoredWord] {
    guard limit > 0, typed.count >= 3 else { return [] }
    guard typed.allSatisfy({ $0.isLetter || $0 == "'" }) else { return [] }
    let folded = typed.lowercased()
    guard !dictionary.containsFolded(folded) else { return [] }
    let capitalize = typed.first?.isUppercase ?? false

    var seen = Set<String>()
    var found: [ScoredWord] = []
    for variant in editDistanceOneVariants(of: Array(folded)) {
        guard seen.insert(variant).inserted, let score = dictionary.score(ofFolded: variant) else { continue }
        // Prefix matches can outrank the exact word, so look past the first few and
        // pick the exact fold; fall back to the folded form if it is buried deeper.
        let exact = dictionary.completions(typed: variant, limit: 64)
            .first { $0.text.lowercased() == variant }
        var text = exact?.text ?? variant
        if capitalize, let first = text.first {
            text = first.uppercased() + text.dropFirst()
        }
        found.append(ScoredWord(text: text, score: exact?.score ?? score))
    }
    var byText = Set<String>()
    let unique = found.filter { byText.insert($0.text).inserted }
    let ranked = unique.sorted { a, b in
        a.score != b.score ? a.score > b.score : a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
    }
    return Array(ranked.prefix(limit))
}
