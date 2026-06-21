// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A token paired with its estimated frequency — the scored candidate the
/// seed-deference layer ranks over.
public struct TokenCount: Equatable, Sendable {
    public let token: String
    public let count: UInt32
    public init(token: String, count: UInt32) {
        self.token = token
        self.count = count
    }
}

/// A single learned vocabulary: a ``PrefixIndex`` of seen tokens paired with a
/// ``CountMinSketch`` of their frequencies. `record` learns; `suggestions` turns
/// a typed prefix into frequency-ranked candidates (`clau` → `claude`). The
/// confidence floor and seed deference are deliberately *not* here — this is the
/// single-source ranked-lookup mechanism the seed-aware layer composes over. See
/// `2026-06-21-predictor-prefix-ranking-design`.
public struct Vocabulary: Equatable, Sendable {
    private var index: PrefixIndex
    private var counts: CountMinSketch

    /// A new vocabulary whose frequency sketch has the given dimensions.
    public init(depth: Int, width: Int) {
        index = PrefixIndex()
        counts = CountMinSketch(depth: depth, width: width)
    }

    /// Learn `count` occurrences of `token` (indexes the string, bumps its
    /// frequency). Ignored for an empty token or a zero count — neither adds a
    /// useful suggestion, and recording one would desync the index (token
    /// present) from the sketch (frequency 0).
    public mutating func record(_ token: String, count: UInt32 = 1) {
        guard !token.isEmpty, count > 0 else { return }
        index.insert(token)
        counts.add(token, count: count)
    }

    /// Every token having `prefix` paired with its estimated count, unranked.
    /// Exposes the per-candidate scores the seed-deference layer needs (the
    /// string-only `suggestions` hides them).
    public func candidates(forPrefix prefix: String) -> [TokenCount] {
        index.matching(prefix: prefix).map { TokenCount(token: $0, count: counts.estimate($0)) }
    }

    /// Up to `limit` tokens having `prefix`, ranked by estimated frequency
    /// (descending), ties broken lexicographically (ascending) for a total,
    /// deterministic order. Empty result if `limit <= 0` or no token matches.
    public func suggestions(forPrefix prefix: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let candidates = index.matching(prefix: prefix)
        if candidates.isEmpty { return [] }
        let ranked = candidates.sorted { a, b in
            let ea = counts.estimate(a), eb = counts.estimate(b)
            if ea != eb { return ea > eb }   // higher frequency first
            return a < b                      // tie → lexicographic
        }
        return Array(ranked.prefix(limit))
    }
}
