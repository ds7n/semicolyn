// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Parses a tldr-pages markdown page into command-invocation token sequences.
/// Each example invocation is an inline backtick code span (`git commit
/// --message "{{message}}"`); this extracts those spans and segments them into
/// clean vocabulary, dropping user-substituted `{{placeholders}}` and shell
/// operators. Pure text→tokens — the unigram/bigram decision belongs to
/// ``SeedBuilder``. See `2026-06-21-predictor-seed-ingestion-design`.
public enum TldrParser {
    /// One token sequence per command segment found in `markdown`, in document
    /// order. Each inline code span is split on shell operators (`|`, `&&`, `;`,
    /// `&`) and redirections (`>`, `<`) into separate segments, so a learned
    /// bigram never crosses a command boundary (`… | grep` must not teach
    /// `(arg, grep)`). Prose and headers (no backticks) contribute nothing.
    /// Returns `[]` for a page with no code spans.
    public static func invocations(fromPage markdown: String) -> [[String]] {
        var sequences: [[String]] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            for span in codeSpans(in: String(line)) {
                sequences.append(contentsOf: segments(in: span))
            }
        }
        return sequences
    }

    /// The contents of each paired-backtick span in `line`, in order. An unpaired
    /// trailing backtick opens no span (its content is discarded).
    private static func codeSpans(in line: String) -> [String] {
        var spans: [String] = []
        var current: String? = nil
        for ch in line {
            if ch == "`" {
                if let open = current {
                    spans.append(open)   // closing backtick → emit span
                    current = nil
                } else {
                    current = ""         // opening backtick → start span
                }
            } else {
                current?.append(ch)
            }
        }
        return spans
    }

    /// Segment one code span into command token sequences. A character state
    /// machine, because shell operators are not reliably whitespace-delimited
    /// (`ls;pwd`, `2>&1`): whitespace ends a word; a control operator (`|`/`&`/`;`)
    /// ends the current segment; a redirection (`>`/`<`) ends the segment *and*
    /// discards the in-progress word (the `2` of `2>&1`) plus the rest of the
    /// glued redirection token.
    private static func segments(in span: String) -> [[String]] {
        var out: [[String]] = []
        var segment: [String] = []
        var word = ""
        var skippingRedirect = false

        func flushWord() {
            if let token = cleanToken(word) { segment.append(token) }
            word = ""
        }
        func flushSegment() {
            flushWord()
            if !segment.isEmpty { out.append(segment) }
            segment = []
        }

        for ch in span {
            if ch == " " || ch == "\t" {
                skippingRedirect = false
                flushWord()
            } else if skippingRedirect {
                continue                              // swallow the rest of `>&1`/`>file`
            } else if ch == "|" || ch == "&" || ch == ";" {
                flushSegment()                        // control operator → command boundary
            } else if ch == ">" || ch == "<" {
                word = ""                             // drop the fd-prefix (`2` of `2>&1`)
                flushSegment()
                skippingRedirect = true
            } else {
                word.append(ch)
            }
        }
        flushSegment()
        return out
    }

    /// Normalize one assembled word, or `nil` to drop it: placeholders (anything
    /// carrying `{{`/`}}`) are user args, not vocabulary; one *matched* surrounding
    /// quote pair is stripped; a word that collapses to empty is dropped.
    /// Stripping only a matched pair (not every quote at each end) keeps a
    /// legitimately quote-bearing token like `"'"` (a literal single quote, e.g.
    /// `tr "'" …`) alive as `'` instead of erasing it.
    private static func cleanToken(_ token: String) -> String? {
        if token.isEmpty || token.contains("{{") || token.contains("}}") { return nil }
        var t = Substring(token)
        if t.count >= 2, let first = t.first, first == t.last, first == "\"" || first == "'" {
            t = t.dropFirst().dropLast()
        }
        return t.isEmpty ? nil : String(t)
    }
}
