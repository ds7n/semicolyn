// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Extracts top-level `(command, subcommand)` / `(command, flag)` pairs from a
/// Fig (withfig/autocomplete) TypeScript completion spec. The structured data
/// lives inside a `.ts` module, so this tokenizes the source (consuming comments,
/// strings, and template literals whole to keep brace balance) and walks a frame
/// stack, emitting a member `name` only when it is a direct element of the spec's
/// own top-level `subcommands:` / `options:` array. Returns the same
/// `[[command, member]]` shape ``TldrParser`` does, so ``SeedBuilder`` ingests
/// both identically. See `2026-06-21-predictor-fig-ingestion-design`.
public enum FigSpecParser {
    /// `[command, member]` pairs for every top-level subcommand/flag name in
    /// `source`. `command` is the caller-supplied filename stem (more robust than
    /// parsing the spec's own `name`). `[]` if the spec has no top-level members.
    public static func invocations(fromSpec source: String, command: String) -> [[String]] {
        var results: [[String]] = []
        for member in topLevelMemberNames(in: tokenize(source)) {
            results.append([command, member])
        }
        return results
    }

    // MARK: - Tokenizing

    private enum Token: Equatable {
        case punct(Character)            // one of { } [ ] : ,
        case string(String, template: Bool)
        case ident(String)
    }

    /// Reduce TS source to the only tokens that matter — `{}[]:,`, string/template
    /// literals, identifiers — skipping comments, whitespace, and everything else
    /// (operators, numbers, parens, `;`). Every brace/bracket outside a string or
    /// comment is preserved, so nesting stays balanced.
    private static func tokenize(_ source: String) -> [Token] {
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
                    i += 1   // operators, digits, parens, `;`, `=>` — irrelevant
                    lastSig = c
                }
            }
        }
        return tokens
    }

    /// Whether a `/` in this position opens a regex literal (vs. a division
    /// operator), judged by the preceding significant character. A regex follows
    /// a value-position char — `( , = : [ { ! & | ? ; >` (the `>` of `=>`) — or the
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

    // MARK: - Frame-stack walk

    private enum Frame {
        case object(isTopMember: Bool)
        case array(key: String?, topLevel: Bool)
    }

    /// Walk the token stream, returning the `name` value of every object that is a
    /// direct element of a top-level `subcommands:` / `options:` array (a string
    /// name, or each alias of a `["…","…"]` name array; templated names skipped).
    private static func topLevelMemberNames(in tokens: [Token]) -> [String] {
        var names: [String] = []
        var stack: [Frame] = []
        var pendingKey: String? = nil
        var lastIdent: String? = nil
        var skippingImport = false
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]

            if skippingImport {
                if case .string = token { skippingImport = false }
                idx += 1
                continue
            }

            // Intercept a top-level member's own `name:` value before generic handling.
            if pendingKey == "name", case .object(let isTopMember)? = stack.last, isTopMember {
                if case .string(let value, let template) = token {
                    if !template { names.append(value) }
                    pendingKey = nil
                    idx += 1
                    continue
                }
                if case .punct("[") = token {
                    idx = collectAliasArray(tokens, from: idx, into: &names)
                    pendingKey = nil
                    continue
                }
                pendingKey = nil   // a computed/unhandled name value; fall through
            }

            switch token {
            case .ident(let name):
                if name == "import", stack.isEmpty { skippingImport = true } else { lastIdent = name }
            case .punct(":"):
                pendingKey = lastIdent
                lastIdent = nil
            case .punct("["):
                let topLevel: Bool
                if stack.count == 1, case .object = stack[0] { topLevel = true } else { topLevel = false }
                stack.append(.array(key: pendingKey, topLevel: topLevel))
                pendingKey = nil
            case .punct("{"):
                var isTopMember = false
                if case .array(let key, let topLevel)? = stack.last,
                   topLevel, key == "subcommands" || key == "options" {
                    isTopMember = true
                }
                stack.append(.object(isTopMember: isTopMember))
                pendingKey = nil
            case .punct("]"), .punct("}"):
                if !stack.isEmpty { stack.removeLast() }
                pendingKey = nil
            default:                       // string value, comma, stray punct
                pendingKey = nil
            }
            idx += 1
        }
        return names
    }

    /// Consume a `["a", "b"]` name-alias array starting at the `[` at `start`,
    /// appending each non-template string alias to `names`. Returns the index just
    /// past the matching `]` (bracket-depth balanced).
    private static func collectAliasArray(_ tokens: [Token], from start: Int,
                                          into names: inout [String]) -> Int {
        var idx = start + 1
        var depth = 1
        while idx < tokens.count, depth > 0 {
            switch tokens[idx] {
            case .punct("["): depth += 1
            case .punct("]"): depth -= 1
            case .string(let value, let template) where depth == 1 && !template: names.append(value)
            default: break
            }
            idx += 1
        }
        return idx
    }
}
