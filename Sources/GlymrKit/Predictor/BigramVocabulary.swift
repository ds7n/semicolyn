// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Next-token prediction: learns `(previous, next)` adjacencies and, given a
/// committed `previous` token, ranks the tokens that have followed it (`git` →
/// `status` / `commit`). A bigram is a unigram over a composite key
/// `previous + US + next`, so this is a thin wrapper over ``Vocabulary`` —
/// `nextSource(after:)` exposes one previous token's successors as a plain
/// ``CandidateSource``, which the seed-deference and windowing composers consume
/// unchanged. See `2026-06-21-predictor-bigram-next-token-design`.
public struct BigramVocabulary {
    private var vocab: Vocabulary

    /// ASCII unit separator (0x1F) — a control byte no shell token contains, so
    /// `previous + separator + next` is unambiguous and reversible.
    static let separator: Character = "\u{1F}"
    private static let separatorByte: UInt8 = 0x1F

    /// A new bigram store whose composite-key sketch has the given dimensions
    /// (default: the spec's bigram `4 × 2^16`, wider than the unigram table
    /// because the `(previous, next)` pair space is larger).
    public init(depth: Int = 4, width: Int = 1 << 16) {
        vocab = Vocabulary(depth: depth, width: width)
    }

    /// Learn `count` occurrences of `next` following `previous`. Ignored when
    /// either side is empty, `count` is zero, or either side contains the
    /// separator byte (which would corrupt the encoding) — fail-closed.
    public mutating func record(previous: String, next: String, count: UInt32 = 1) {
        guard !previous.isEmpty, !next.isEmpty, count > 0,
              !previous.utf8.contains(Self.separatorByte),
              !next.utf8.contains(Self.separatorByte) else { return }
        vocab.record(previous + String(Self.separator) + next, count: count)
    }

    /// A ``CandidateSource`` scoped to the successors of `previous`:
    /// `candidates(forPrefix:)` ranks the next tokens (decoded to bare strings),
    /// so it plugs straight into ``SeededSuggester`` and ``AggregateCandidateSource``.
    public func nextSource(after previous: String) -> any CandidateSource {
        NextTokenSource(vocab: vocab, previous: previous)
    }

    /// Successors of `previous` having `prefix`, byte-sorted with estimated
    /// counts — sugar over `nextSource(after:).candidates(forPrefix:)`. Empty
    /// `prefix` (the default) returns every known successor.
    public func candidates(after previous: String, prefix: String = "") -> [TokenCount] {
        nextSource(after: previous).candidates(forPrefix: prefix)
    }
}

/// Adapts one previous token's slice of a composite-key ``Vocabulary`` into a
/// next-token ``CandidateSource``: queries `previous + US + prefix`, then strips
/// the `previous + US` lead off each composite key to recover the bare `next`.
struct NextTokenSource: CandidateSource {
    let vocab: Vocabulary
    let previous: String

    func candidates(forPrefix prefix: String) -> [TokenCount] {
        let lead = previous + String(BigramVocabulary.separator)
        // Strip the lead by byte count and decode the remainder — byte-consistent
        // with the module and immune to a leading combining mark a Character-wise
        // drop could mishandle.
        let dropBytes = lead.utf8.count
        return vocab.candidates(forPrefix: lead + prefix).map { candidate in
            let next = String(decoding: candidate.token.utf8.dropFirst(dropBytes), as: UTF8.self)
            return TokenCount(token: next, count: candidate.count)
        }
    }
}
