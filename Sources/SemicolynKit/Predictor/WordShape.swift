// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A typed token split into surrounding punctuation and the word to look up.
public struct LookupWord: Equatable, Sendable {
    public let leading: String
    public let word: String
    public let trailing: String

    public init(leading: String, word: String, trailing: String) {
        self.leading = leading
        self.word = word
        self.trailing = trailing
    }
}

private let leadingPunctuation: Set<Character> = ["(", "\"", "'", "[", "{", "<", "\u{201C}", "\u{2018}"]
private let trailingPunctuation: Set<Character> = [
    ",", ".", "?", "!", ";", ":", ")", "]", "}", "\"", "'", ">", "\u{201D}", "\u{2019}",
]

/// True when the token looks like a flag, path, or assignment, which is never trimmed.
private func isPathOrFlagShaped(_ token: String) -> Bool {
    guard let first = token.first else { return false }
    if first == "-" || first == "~" || first == "/" { return true }
    if first == "." && token.dropFirst().first == "/" { return true }
    return token.contains("/") || token.contains("=")
}

/// Splits `token` into leading punctuation, the word to look up, and trailing punctuation.
/// Path and flag shaped tokens are returned whole as the word.
public func lookupWord(fromToken token: String) -> LookupWord {
    if isPathOrFlagShaped(token) {
        return LookupWord(leading: "", word: token, trailing: "")
    }
    let chars = Array(token)
    var start = 0
    while start < chars.count, leadingPunctuation.contains(chars[start]) { start += 1 }
    var end = chars.count
    while end > start, trailingPunctuation.contains(chars[end - 1]) { end -= 1 }
    return LookupWord(
        leading: String(chars[0..<start]),
        word: String(chars[start..<end]),
        trailing: String(chars[end...])
    )
}

private func isCased(lower c: Character) -> Bool {
    let s = String(c)
    return s.lowercased() == s && s.uppercased() != s
}

private func isCased(upper c: Character) -> Bool {
    let s = String(c)
    return s.uppercased() == s && s.lowercased() != s
}

/// Returns `candidate` in the case form implied by `typed`, or nil if the case conflicts.
/// A lowercase typed character matches either case; any other must match exactly. When the
/// first typed character is uppercase and `candidate` is all lowercase, the candidate is
/// returned with its first character uppercased (sentence-start capitalization).
public func caseMatchedForm(typed: String, candidate: String) -> String? {
    if candidate.isEmpty { return nil }
    if typed.isEmpty { return candidate }
    let t = Array(typed)
    let c = Array(candidate)
    if c.count < t.count { return nil }

    var capitalizeFirst = false
    var startIndex = 0
    if isCased(upper: t[0]), candidate == candidate.lowercased() {
        guard String(t[0]).lowercased() == String(c[0]) else { return nil }
        capitalizeFirst = true
        startIndex = 1
    }
    for i in startIndex..<t.count {
        if isCased(lower: t[i]) {
            if String(t[i]).lowercased() != String(c[i]).lowercased() { return nil }
        } else if t[i] != c[i] {
            return nil
        }
    }
    guard capitalizeFirst else { return candidate }
    return String(c[0]).uppercased() + String(c[1...])
}
