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
public struct BigramVocabulary: Sendable {
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

    /// The composite key for a `(previous, next)` pair, or `nil` when the pair is
    /// unrecordable: either side empty, or either side carrying the separator byte
    /// (which would corrupt the encoding). The single home of the bigram
    /// encode-and-guard invariant — both the windowless and windowed
    /// (``RollingBigramVocabulary``) stores call it, so the rule can't drift.
    static func compositeKey(previous: String, next: String) -> String? {
        guard !previous.isEmpty, !next.isEmpty,
              !previous.utf8.contains(separatorByte),
              !next.utf8.contains(separatorByte) else { return nil }
        return previous + String(separator) + next
    }

    /// Learn `count` occurrences of `next` following `previous`. Ignored when the
    /// pair is unrecordable (see ``compositeKey(previous:next:)``) or `count` is
    /// zero — fail-closed.
    public mutating func record(previous: String, next: String, count: UInt32 = 1) {
        guard count > 0, let key = Self.compositeKey(previous: previous, next: next) else { return }
        vocab.record(key, count: count)
    }

    /// A ``CandidateSource`` scoped to the successors of `previous`:
    /// `candidates(forPrefix:)` ranks the next tokens (decoded to bare strings),
    /// so it plugs straight into ``SeededSuggester`` and ``AggregateCandidateSource``.
    public func nextSource(after previous: String) -> any CandidateSource {
        NextTokenSource(base: vocab, previous: previous)
    }

    /// Successors of `previous` having `prefix`, byte-sorted with estimated
    /// counts — sugar over `nextSource(after:).candidates(forPrefix:)`. Empty
    /// `prefix` (the default) returns every known successor.
    public func candidates(after previous: String, prefix: String = "") -> [TokenCount] {
        nextSource(after: previous).candidates(forPrefix: prefix)
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x42, 0x47, 0x4d]  // "GBGM"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    /// Serialize the seed/store blob: `magic | version | inner-vocabulary blob`.
    /// The distinct magic is the type guard — a bigram store and a unigram
    /// ``Vocabulary`` blob can't be loaded as each other.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        out.append(contentsOf: vocab.serialize())
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic/version or if
    /// the inner-vocabulary blob is rejected (the ``Vocabulary`` deserializer
    /// already rejects any trailing slack, so the rest-of-bytes payload needs no
    /// length prefix).
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let vocab = Vocabulary(deserializing: Array(bytes[Self.headerSize...])) else { return nil }
        self.vocab = vocab
    }
}

/// Adapts one previous token's slice of any composite-key ``CandidateSource``
/// into a next-token source: queries `previous + US + prefix`, then strips the
/// `previous + US` lead off each composite key to recover the bare `next`. Works
/// over a single ``Vocabulary`` (``BigramVocabulary``) or a windowed
/// ``AggregateCandidateSource`` (``RollingBigramVocabulary``) alike — it touches
/// only `candidates(forPrefix:)`.
struct NextTokenSource: CandidateSource {
    let base: any CandidateSource
    let previous: String

    func candidates(forPrefix prefix: String) -> [TokenCount] {
        let lead = previous + String(BigramVocabulary.separator)
        // Strip the lead by byte count and decode the remainder — byte-consistent
        // with the module and immune to a leading combining mark a Character-wise
        // drop could mishandle.
        let dropBytes = lead.utf8.count
        return base.candidates(forPrefix: lead + prefix).map { candidate in
            let next = String(decoding: candidate.token.utf8.dropFirst(dropBytes), as: UTF8.self)
            return TokenCount(token: next, count: candidate.count)
        }
    }
}
