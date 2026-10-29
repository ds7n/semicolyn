// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Reads Fig (withfig/autocomplete) TypeScript completion specs. The structured
/// data lives inside a `.ts` module, so this tokenizes the source (consuming
/// comments, strings, regex and template literals whole to keep brace balance);
/// `spec(fromSource:command:maxDepth:)` (in `FigTree.swift`) walks the tokens into
/// a nested ``FigCommandSpec``.
public enum FigSpecParser {
    // MARK: - Tokenizing

    enum Token: Equatable {
        case punct(Character)            // one of { } [ ] : , (plus ( ) = . with operators)
        case string(String, template: Bool)
        case ident(String)
        case spread                      // `...`, only with operators
    }

    /// Reduce TS source to the only tokens that matter, `{}[]:,`, string/template
    /// literals, identifiers, skipping comments, whitespace, and everything else
    /// (operators, numbers, parens, `;`). Every brace/bracket outside a string or
    /// comment is preserved, so nesting stays balanced. With `operators`, the tokens
    /// needed to resolve references are kept too: `(`, `)`, `.`, a lone assignment
    /// `=` (not `==`, `=>`, `<=`, ...) and `...` as ``Token/spread``.
    static func tokenize(_ source: String, operators: Bool = false) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        let n = chars.count
        var i = 0
        var lastSig: Character? = nil   // last significant char, for regex/division disambiguation
        while i < n {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1
            case "/" where i + 1 < n && chars[i + 1] == "/":
                while i < n && chars[i] != "\n" { i += 1 }
            case "/" where i + 1 < n && chars[i + 1] == "*":
                i += 2
                while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, n)
            case "/" where startsRegex(after: lastSig):
                // Consume a regex literal opaquely so an unbalanced bracket/brace
                // inside it (`/]/`, `/}/`) can't desync the frame stack.
                i = skipRegex(chars, from: i)
                lastSig = "/"
            case "\"", "'":
                let (s, next) = readString(chars, from: i, quote: c)
                tokens.append(.string(s, template: false))
                i = next
                lastSig = c
            case "`":
                let (s, next) = readString(chars, from: i, quote: "`")
                tokens.append(.string(s, template: true))
                i = next
                lastSig = "`"
            case "{", "}", "[", "]", ":", ",":
                tokens.append(.punct(c))
                i += 1
                lastSig = c
            default:
                if isIdentStart(c) {
                    var j = i + 1
                    while j < n && isIdentContinue(chars[j]) { j += 1 }
                    tokens.append(.ident(String(chars[i..<j])))
                    lastSig = chars[j - 1]
                    i = j
                } else {
                    if operators, let (token, width) = operatorToken(chars, at: i) {
                        tokens.append(token)
                        i += width
                        lastSig = c
                        continue
                    }
                    i += 1   // operators, digits, parens, `;`, `=>`, irrelevant
                    lastSig = c
                }
            }
        }
        return tokens
    }

    /// The reference-resolution token starting at `i` and its width, or nil.
    private static func operatorToken(_ chars: [Character], at i: Int) -> (Token, Int)? {
        let n = chars.count
        switch chars[i] {
        case "(", ")":
            return (.punct(chars[i]), 1)
        case "." where i + 2 < n && chars[i + 1] == "." && chars[i + 2] == ".":
            return (.spread, 3)
        case ".":
            return (.punct("."), 1)
        case "=":
            let next: Character? = i + 1 < n ? chars[i + 1] : nil
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            if next == "=" || next == ">" { return nil }
            if let previous, "=!<>+-*/%&|^?".contains(previous) { return nil }
            return (.punct("="), 1)
        default:
            return nil
        }
    }

    /// Whether a `/` in this position opens a regex literal (vs. a division
    /// operator), judged by the preceding significant character. A regex follows
    /// a value-position char, `( , = : [ { ! & | ? ; >` (the `>` of `=>`), or the
    /// start of input; division follows a completed value (identifier, `)`, `]`).
    private static func startsRegex(after lastSig: Character?) -> Bool {
        guard let last = lastSig else { return true }
        return "(,=:[{!&|?;>".contains(last)
    }

    /// Index just past a regex literal whose opening `/` is at `start`. A `/`
    /// inside a `[…]` character class does not close it; backslash escapes the next
    /// char. Trailing flag letters are consumed.
    private static func skipRegex(_ chars: [Character], from start: Int) -> Int {
        let n = chars.count
        var i = start + 1
        var inClass = false
        while i < n {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" { inClass = true } else if c == "]" { inClass = false }
            else if c == "/" && !inClass { i += 1; break }
            i += 1
        }
        while i < n && chars[i].isLetter { i += 1 }   // regex flags (g, i, m, …)
        return i
    }

    /// Read a quoted literal starting at the opening `quote` at `start`; returns
    /// its contents and the index just past the closing quote. Backslash escapes
    /// the next character; an unterminated literal consumes to end of input. For a
    /// template (`` ` ``) the contents (including `${…}`) are taken verbatim, so
    /// their braces never reach the token stream.
    private static func readString(_ chars: [Character], from start: Int,
                                   quote: Character) -> (String, Int) {
        var s = ""
        var i = start + 1
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "\\" {
                i += 1
                if i < n { s.append(chars[i]); i += 1 }
                continue
            }
            if c == quote { return (s, i + 1) }
            s.append(c)
            i += 1
        }
        return (s, n)
    }

    private static func isIdentStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter
    }

    private static func isIdentContinue(_ c: Character) -> Bool {
        isIdentStart(c) || c.isNumber
    }
}
