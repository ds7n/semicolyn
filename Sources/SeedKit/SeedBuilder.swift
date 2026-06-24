// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit

/// Accumulates parsed token sequences into a unigram ``Vocabulary`` and a
/// next-token ``BigramVocabulary``, then serializes both to the seed blob format.
/// Each occurrence counts once — natural corpus frequency does the ranking, and
/// the `seed_weight` thumb-on-the-scale is applied later at query time by
/// ``SeededSuggester``, never baked into the stored counts. So a seed blob is a
/// plain frequency fingerprint, byte-identical in format to a user's learned
/// sketch. See `2026-06-21-predictor-seed-ingestion-design`.
public struct SeedBuilder {
    private var unigrams: Vocabulary
    private var bigrams: BigramVocabulary

    /// A new builder whose sketches use the spec's seed dimensions (unigram
    /// `4 × 2^14`, bigram `4 × 2^16`), matching the runtime stores.
    public init() {
        unigrams = Vocabulary(depth: 4, width: 1 << 14)
        bigrams = BigramVocabulary(depth: 4, width: 1 << 16)
    }

    /// Fold one invocation's tokens in: each token is a unigram occurrence, each
    /// adjacent `(previous, next)` pair a bigram occurrence. A lone token forms no
    /// pair.
    public mutating func ingest(_ tokens: [String]) {
        for token in tokens { unigrams.record(token) }
        guard tokens.count >= 2 else { return }
        for i in 1..<tokens.count {
            bigrams.record(previous: tokens[i - 1], next: tokens[i])
        }
    }

    /// The serialized seed blobs: the unigram ``Vocabulary`` and the next-token
    /// ``BigramVocabulary``, each in its self-describing fail-closed format.
    public func blobs() -> (unigram: [UInt8], bigram: [UInt8]) {
        (unigram: unigrams.serialize(), bigram: bigrams.serialize())
    }
}
