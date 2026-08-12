// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A `SeededSuggester` variant that blends TWO seed domains, a CLI seed and a prose
/// seed, weighted by a prose `bias` in `[0,1]`. Layer-2 (confident-learned) fast path
/// is identical to `SeededSuggester`; only the fill path differs. `bias == 0` reduces
/// to CLI-only (today's behavior); `bias == 1` is prose-only.
struct DualSeedSuggester {
    let learned: any CandidateSource
    let cliSeed: any CandidateSource
    let proseSeed: any CandidateSource
    let bias: Double
    var config: SuggestionConfig

    init(learned: any CandidateSource, cliSeed: any CandidateSource,
         proseSeed: any CandidateSource, bias: Double, config: SuggestionConfig) {
        self.learned = learned
        self.cliSeed = cliSeed
        self.proseSeed = proseSeed
        self.bias = min(1.0, max(0.0, bias))
        self.config = config
    }

    func suggestions(forPrefix prefix: String) -> [String] {
        guard config.topK > 0 else { return [] }

        let confident = learned.candidates(forPrefix: prefix)
            .filter { $0.count >= config.confidenceFloor }
        if confident.count >= config.topK {
            return ranked(confident.map { (token: $0.token, score: Double($0.count)) })
        }

        var scores: [String: Double] = [:]
        for c in confident { scores[c.token] = Double(c.count) }
        let cliW = config.seedWeight * (1.0 - bias)
        let proseW = config.seedWeight * bias
        for s in cliSeed.candidates(forPrefix: prefix) {
            scores[s.token, default: 0] += cliW * Double(s.count)
        }
        for s in proseSeed.candidates(forPrefix: prefix) {
            scores[s.token, default: 0] += proseW * Double(s.count)
        }
        // A zero-weighted seed must not inject a token via a 0 score; drop zeros.
        let nonzero = scores.filter { $0.value > 0 }
        return ranked(nonzero.map { (token: $0.key, score: $0.value) })
    }

    private func ranked(_ scored: [(token: String, score: Double)]) -> [String] {
        let sorted = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.token.utf8.lexicographicallyPrecedes(b.token.utf8)
        }
        return Array(sorted.prefix(config.topK).map { $0.token })
    }
}
