// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Tunable knobs for seed-deferred suggestion. Defaults are the spec's starting
/// points (`top_k = 3`, `confidence_floor = 2`, `seed_weight = 0.5`) — empirical,
/// not magic.
public struct SuggestionConfig: Equatable, Sendable {
    /// Suggestion-row slot count.
    public var topK: Int
    /// Minimum learned occurrences for a token to count as a confident candidate.
    public var confidenceFloor: UInt32
    /// Thumb-on-the-scale multiplier applied to seed counts when blending.
    public var seedWeight: Double

    public init(topK: Int = 3, confidenceFloor: UInt32 = 2, seedWeight: Double = 0.5) {
        self.topK = topK
        self.confidenceFloor = confidenceFloor
        self.seedWeight = seedWeight
    }
}

/// Combines a mutable **learned** ``Vocabulary`` with a pinned read-only **seed**
/// to produce suggestions that are useful on day one and that let the seed step
/// aside, per-prefix and invisibly, as the user builds vocabulary. Implements the
/// two-layer deference of `2026-06-21-predictor-seed-deference-design`.
public struct SeededSuggester {
    public var learned: Vocabulary
    public let seed: Vocabulary
    public var config: SuggestionConfig

    public init(learned: Vocabulary, seed: Vocabulary, config: SuggestionConfig = .init()) {
        self.learned = learned
        self.seed = seed
        self.config = config
    }

    /// Learn `count` occurrences of `token` into the learned vocabulary. The seed
    /// is pinned and never mutated.
    public mutating func record(_ token: String, count: UInt32 = 1) {
        learned.record(token, count: count)
    }

    /// Up to `topK` suggestions for `prefix`, applying per-prefix gating
    /// (Layer 2) and, where the seed is consulted, per-token weighting (Layer 1).
    public func suggestions(forPrefix prefix: String) -> [String] {
        guard config.topK > 0 else { return [] }

        let confident = learned.candidates(forPrefix: prefix)
            .filter { $0.count >= config.confidenceFloor }

        // Layer 2 fast path: enough confident learned candidates → seed not
        // consulted; rank by learned count alone.
        if confident.count >= config.topK {
            return ranked(confident.map { (token: $0.token, score: Double($0.count)) })
        }

        // Fill path: blend confident-learned with seed (Layer 1 weighting).
        var scores: [String: Double] = [:]
        for c in confident { scores[c.token] = Double(c.count) }
        for s in seed.candidates(forPrefix: prefix) {
            scores[s.token, default: 0] += config.seedWeight * Double(s.count)
        }
        return ranked(scores.map { (token: $0.key, score: $0.value) })
    }

    /// Sort scored tokens by score descending, ties by token ascending (UTF-8
    /// bytes — the module's consistent total order), and take `topK`.
    private func ranked(_ scored: [(token: String, score: Double)]) -> [String] {
        let sorted = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.token.utf8.lexicographicallyPrecedes(b.token.utf8)
        }
        return Array(sorted.prefix(config.topK).map { $0.token })
    }
}
