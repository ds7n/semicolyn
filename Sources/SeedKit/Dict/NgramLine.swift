// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One surviving Google Books n-gram: its space-separated tokens and the match count summed
/// over the years kept.
public struct NgramLine: Equatable, Sendable {
    public let tokens: [String]
    public let count: UInt64

    public init(tokens: [String], count: UInt64) {
        self.tokens = tokens
        self.count = count
    }
}

/// Parses one Google Books v3 line, `ngram<TAB>year,match,volume<TAB>...`.
///
/// Sums `match` over entries with `year >= minYear`, skipping malformed entries; the sum
/// saturates at `UInt64.max`. Returns nil when there is no tab, the sum is 0, any token
/// contains `_` (POS-tagged forms and tag-only entries), or any token has no letter.
public func parseNgramLine(_ line: Substring, minYear: Int) -> NgramLine? {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 2 else { return nil }

    let tokens = fields[0].split(separator: " ", omittingEmptySubsequences: true)
    guard !tokens.isEmpty else { return nil }
    for token in tokens {
        if token.contains("_") { return nil }
        if !token.contains(where: { $0.isLetter }) { return nil }
    }

    var total: UInt64 = 0
    for entry in fields.dropFirst() {
        let parts = entry.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, let year = Int(parts[0]), let match = UInt64(parts[1]) else { continue }
        guard year >= minYear else { continue }
        let (sum, overflow) = total.addingReportingOverflow(match)
        total = overflow ? UInt64.max : sum
    }
    guard total > 0 else { return nil }
    return NgramLine(tokens: tokens.map(String.init), count: total)
}

/// Incremental, chunk-oriented filter over Google Books lines. Feed raw byte chunks of any
/// size (lines may straddle chunks); surviving lines are appended to `out` as
/// `ngram<TAB>count\n`. Call ``finish(into:)`` at end of input to flush an unterminated
/// last line.
public struct NgramStreamFilter: Sendable {
    private let minYear: Int
    private let minCount: UInt64
    private let vocab: Set<String>?
    private var carry: [UInt8] = []

    /// - Parameters:
    ///   - minYear: first year (inclusive) whose counts are summed.
    ///   - minCount: lines whose summed count is below this are dropped.
    ///   - vocab: when set, every token lowercased must be a member for the line to survive.
    public init(minYear: Int, minCount: UInt64, vocab: Set<String>?) {
        self.minYear = minYear
        self.minCount = minCount
        self.vocab = vocab
    }

    /// Consumes a chunk, emitting every complete line it (together with any carried bytes) holds.
    public mutating func feed(_ chunk: [UInt8], into out: inout [UInt8]) {
        var start = 0
        let n = chunk.count
        while start < n {
            guard let nl = chunk[start...].firstIndex(of: 0x0A) else { break }
            if carry.isEmpty {
                emit(chunk[start..<nl], into: &out)
            } else {
                carry.append(contentsOf: chunk[start..<nl])
                emit(carry[...], into: &out)
                carry.removeAll(keepingCapacity: true)
            }
            start = nl + 1
        }
        if start < n { carry.append(contentsOf: chunk[start...]) }
    }

    /// Flushes a final line that had no trailing newline.
    public mutating func finish(into out: inout [UInt8]) {
        guard !carry.isEmpty else { return }
        emit(carry[...], into: &out)
        carry.removeAll()
    }

    private func emit(_ bytes: ArraySlice<UInt8>, into out: inout [UInt8]) {
        var bytes = bytes
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return }
        // Cheap allocation-free reject for the vast majority of lines; survivors go through
        // the authoritative parser below.
        guard Self.byteSum(bytes, minYear: minYear) >= max(minCount, 1) else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        guard let parsed = parseNgramLine(Substring(text), minYear: minYear),
              parsed.count >= minCount else { return }
        if let vocab, !parsed.tokens.allSatisfy({ vocab.contains($0.lowercased()) }) { return }
        out.append(contentsOf: parsed.tokens.joined(separator: " ").utf8)
        out.append(0x09)
        out.append(contentsOf: String(parsed.count).utf8)
        out.append(0x0A)
    }

    /// Byte-level mirror of the summing rule in ``parseNgramLine(_:minYear:)``: never smaller
    /// than the real sum, so a result below the threshold is a safe reject. Returns 0 for a
    /// line with no tab or with `_` in the ngram field (both rejected by the real parser).
    static func byteSum(_ bytes: ArraySlice<UInt8>, minYear: Int) -> UInt64 {
        var total: UInt64 = 0
        var i = bytes.startIndex
        let end = bytes.endIndex
        // Ngram field: reject on '_', then find the first tab.
        while i < end, bytes[i] != 0x09 {
            if bytes[i] == 0x5F { return 0 }
            i += 1
        }
        while i < end {
            i += 1   // skip the tab
            // year
            var year = 0
            var digits = 0
            if i < end, bytes[i] == 0x2B { i += 1 }
            while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                year = year &* 10 &+ Int(bytes[i] &- 0x30)
                digits += 1
                i += 1
            }
            var ok = digits > 0 && i < end && bytes[i] == 0x2C
            var match: UInt64 = 0
            if ok {
                i += 1
                var mdigits = 0
                if i < end, bytes[i] == 0x2B { i += 1 }
                while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    let (m1, o1) = match.multipliedReportingOverflow(by: 10)
                    let (m2, o2) = m1.addingReportingOverflow(UInt64(bytes[i] &- 0x30))
                    match = (o1 || o2) ? UInt64.max : m2
                    mdigits += 1
                    i += 1
                }
                ok = mdigits > 0 && year >= minYear
            }
            if ok {
                let (sum, overflow) = total.addingReportingOverflow(match)
                total = overflow ? UInt64.max : sum
            }
            while i < end, bytes[i] != 0x09 { i += 1 }
        }
        return total
    }
}
