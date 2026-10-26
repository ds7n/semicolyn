// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One command of a typed shell line: the space-delimited tokens between separators.
public struct CommandSegment: Equatable, Sendable {
    /// Every token of the segment, including a trailing partial one (quotes kept as typed).
    public let words: [String]
    /// True only when the segment follows a single `|`.
    public let afterPipe: Bool

    public init(words: [String], afterPipe: Bool) {
        self.words = words
        self.afterPipe = afterPipe
    }
}

/// Whether a typed line looks like a shell command, prose, or cannot be told yet.
public enum LineKind: Equatable, Sendable {
    case command, prose, undecided
}

/// What the predictor needs to know about the line being typed.
public struct LineContext: Equatable, Sendable {
    public let kind: LineKind
    /// Completed words of the last segment, wrappers removed.
    public let segmentWords: [String]
    public let afterPipe: Bool
    /// The token being typed ("" after a space or separator).
    public let currentToken: String
    /// Lookup form of the last completed word in the last segment, nil at segment start.
    public let previousWord: String?
    /// True when a quote is left open at the end of the line.
    public let inQuotes: Bool

    public init(
        kind: LineKind, segmentWords: [String], afterPipe: Bool, currentToken: String,
        previousWord: String?, inQuotes: Bool
    ) {
        self.kind = kind
        self.segmentWords = segmentWords
        self.afterPipe = afterPipe
        self.currentToken = currentToken
        self.previousWord = previousWord
        self.inQuotes = inQuotes
    }
}

/// The options of a wrapper command that take a value in the next word.
private struct WrapperOptions {
    /// Short option letters that take a value (`-u alice`, or attached: `-ualice`).
    var valueLetters: Set<Character> = []
    /// Long options that take a value in the next word (`--user alice`).
    var valueLongOptions: Set<String> = []
}

private let wrapperCommands: [String: WrapperOptions] = [
    "sudo": WrapperOptions(
        valueLetters: ["u", "g", "p", "C", "D", "r", "t", "T", "U"],
        valueLongOptions: ["--user", "--group", "--prompt", "--chdir", "--close-from", "--role",
                           "--type", "--command-timeout", "--other-user"]),
    "doas": WrapperOptions(valueLetters: ["u", "C"]),
    "env": WrapperOptions(valueLetters: ["u", "C"], valueLongOptions: ["--unset", "--chdir"]),
    "nice": WrapperOptions(valueLetters: ["n"], valueLongOptions: ["--adjustment"]),
    "watch": WrapperOptions(valueLetters: ["n"], valueLongOptions: ["--interval"]),
    "xargs": WrapperOptions(
        valueLetters: ["I", "n", "P", "L", "s", "d", "a", "E"],
        valueLongOptions: ["--max-args", "--max-procs", "--max-lines", "--max-chars", "--delimiter",
                           "--arg-file"]),
    "time": WrapperOptions(valueLetters: ["f", "o"], valueLongOptions: ["--format", "--output"]),
    "exec": WrapperOptions(valueLetters: ["a"]),
    "nohup": WrapperOptions(),
    "command": WrapperOptions(),
]

/// True when option `word` of a wrapper with `options` leaves its value to the next word:
/// a listed long option, or a short cluster whose first value letter is its last letter
/// (`-u`, `-Eu`; in `-ualice` the value is attached).
private func optionTakesNextWord(_ word: String, _ options: WrapperOptions) -> Bool {
    if word.hasPrefix("--") { return options.valueLongOptions.contains(word) }
    let letters = word.dropFirst()
    guard let first = letters.firstIndex(where: { options.valueLetters.contains($0) }) else {
        return false
    }
    return letters.index(after: first) == letters.endIndex
}

/// Drops leading wrapper commands and, after each, its options (`-x`, with their values:
/// `sudo -u alice`) and assignments (`A=1`). Words without a leading wrapper are returned
/// untouched.
public func strippingWrappers(_ words: [String]) -> [String] {
    var i = 0
    while i < words.count, let options = wrapperCommands[words[i]] {
        i += 1
        while i < words.count, words[i].hasPrefix("-") || words[i].contains("=") {
            let takesValue = words[i].hasPrefix("-") && optionTakesNextWord(words[i], options)
            i += takesValue ? 2 : 1
        }
    }
    return Array(words[min(i, words.count)...])
}

private struct LineScan {
    /// All segments, including a trailing empty one after a separator or a trailing space.
    var segments: [CommandSegment] = []
    /// True when the line ends in the middle of a token.
    var tokenPending = false
    var inQuotes = false
    var sawSeparator = false
}

private func scanLine(_ line: String) -> LineScan {
    var scan = LineScan()
    var words: [String] = []
    var token = ""
    var afterPipe = false
    var quote: Character?
    let chars = Array(line)
    var i = 0

    func endToken() {
        if token.isEmpty { return }
        words.append(token)
        token = ""
    }
    func endSegment(nextAfterPipe: Bool) {
        endToken()
        scan.segments.append(CommandSegment(words: words, afterPipe: afterPipe))
        words = []
        afterPipe = nextAfterPipe
        scan.sawSeparator = true
    }

    while i < chars.count {
        let c = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        i += 1
        if let q = quote {
            // Words are still space-delimited inside quotes; only separators become text.
            if c == " " || c == "\t" {
                endToken()
                continue
            }
            token.append(c)
            if q == "\"", c == "\\", let n = next {
                token.append(n)
                i += 1
            } else if c == q {
                quote = nil
            }
            continue
        }
        switch c {
        case "\\":
            token.append(c)
            if let n = next {
                token.append(n)
                i += 1
            }
        case "'", "\"":
            quote = c
            token.append(c)
        case " ", "\t":
            endToken()
        case "|":
            // `||` is a list separator; `|` and `|&` (stderr too) pipe into the next segment.
            if next == "|" || next == "&" { i += 1 }
            endSegment(nextAfterPipe: next != "|")
        case "&" where token.last == ">" || token.last == "<" || next == ">":
            // A redirection, not a separator: `2>&1`, `>&2`, `<&3`, `&>log`, `&>>log`.
            token.append(c)
        case "&":
            if next == "&" { i += 1 }
            endSegment(nextAfterPipe: false)
        case ";", "`":
            endSegment(nextAfterPipe: false)
        case "$" where next == "(":
            i += 1
            endSegment(nextAfterPipe: false)
        default:
            token.append(c)
        }
    }
    scan.tokenPending = !token.isEmpty
    scan.inQuotes = quote != nil
    endToken()
    scan.segments.append(CommandSegment(words: words, afterPipe: afterPipe))
    return scan
}

/// Splits `line` into command segments at unquoted `|`, `|&`, `||`, `;`, `&&`, `&`, `$(` and
/// backtick. An `&` inside a redirection (`2>&1`, `&>log`) stays part of its word.
/// Empty segments (for example after a trailing separator) are omitted.
public func commandSegments(of line: String) -> [CommandSegment] {
    scanLine(line).segments.filter { !$0.words.isEmpty }
}

private func isFlag(_ word: String) -> Bool { word.hasPrefix("-") && word.count > 1 }

private func isPathShaped(_ word: String) -> Bool {
    word.contains("/") || word.hasPrefix("./") || word.hasPrefix("~/")
}

/// Classifies the line and extracts the context around the token being typed.
public func lineContext(line: String, isKnownTool: (String) -> Bool) -> LineContext {
    let scan = scanLine(line)
    let last = scan.segments.last ?? CommandSegment(words: [], afterPipe: false)
    var completed = last.words
    var currentToken = ""
    if scan.tokenPending, let partial = completed.popLast() { currentToken = partial }

    let segmentWords = strippingWrappers(completed)
    let previousWord = completed.last.map { lookupWord(fromToken: $0).word }

    let kind: LineKind
    if scan.inQuotes {
        kind = .prose
    } else if let first = segmentWords.first, isKnownTool(first) {
        kind = .command
    } else if completed.contains(where: { isFlag($0) || isPathShaped($0) }) || scan.sawSeparator {
        kind = .command
    } else if completed.count >= 2 {
        kind = .prose
    } else {
        kind = .undecided
    }

    return LineContext(
        kind: kind, segmentWords: segmentWords, afterPipe: last.afterPipe,
        currentToken: currentToken, previousWord: previousWord, inQuotes: scan.inQuotes)
}
