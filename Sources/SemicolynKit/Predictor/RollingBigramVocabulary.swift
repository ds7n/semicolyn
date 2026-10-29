// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Next-token prediction with daily time-windowing: a hot `today` plus
/// `rolling_7d/30d/90d` pre-aggregates over `(previous, next)` adjacencies.
/// `record` writes today; `rollover` (called at user-local midnight) seals today
/// and slides each window; `nextSource(after:window:)` exposes a previous token's
/// successors as `today ⊕ rolling_W`. A windowed bigram is a windowed unigram over
/// the composite key `previous + US + next` (``BigramKey``), so this wraps
/// ``RollingVocabulary``. See
/// `2026-06-21-predictor-bigram-rollover-design`.
public struct RollingBigramVocabulary: Equatable, Sendable {
    private var rolling: RollingVocabulary

    /// A new windowed bigram store whose composite-key sketches have the given
    /// dimensions (default: the spec's bigram `4 × 2^16`, wider than the unigram
    /// table because the `(previous, next)` pair space is larger).
    public init(depth: Int = 4, width: Int = 1 << 16) {
        rolling = RollingVocabulary(depth: depth, width: width)
    }

    /// Learn `count` occurrences of `next` following `previous` into today's
    /// sketch. Ignored when the pair is unrecordable
    /// (see ``BigramKey/compositeKey(previous:next:)``) or `count` is zero.
    public mutating func record(previous: String, next: String, count: UInt32 = 1,
                            storeLiteral: Bool = true) {
        guard count > 0,
              let key = BigramKey.compositeKey(previous: previous, next: next) else { return }
        rolling.record(key, count: count, storeLiteral: storeLiteral)
    }

    /// Seal today into the rolling pre-aggregates and start a fresh day —
    /// inherited verbatim from ``RollingVocabulary`` (the composite key is just a
    /// string to the rollover arithmetic).
    public mutating func rollover() {
        rolling.rollover()
    }

    /// A ``CandidateSource`` of `previous`'s successors over `today ⊕ rolling_W`,
    /// next tokens decoded to bare strings, for the ranker's next-word mode.
    public func nextSource(after previous: String, window: RollingWindow) -> any CandidateSource {
        NextTokenSource(base: rolling.learnedSource(window: window), previous: previous)
    }

    /// Successors of `previous` having `prefix` over the given window, byte-sorted
    /// with estimated counts — sugar over `nextSource(after:window:)`. Empty
    /// `prefix` (the default) returns every known successor.
    public func candidates(after previous: String, window: RollingWindow,
                           prefix: String = "") -> [TokenCount] {
        nextSource(after: previous, window: window).candidates(forPrefix: prefix)
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x52, 0x42, 0x47]  // "GRBG"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    /// Serialize the windowed bigram state: `magic | version | inner
    /// RollingVocabulary blob`. The distinct magic guards against loading a unigram
    /// `GRLV` state as a bigram store.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        out.append(contentsOf: rolling.serialize())
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic/version or if
    /// the inner rolling state is rejected (which already forbids trailing slack,
    /// so the rest-of-bytes payload needs no length prefix).
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let rolling = RollingVocabulary(deserializing: Array(bytes[Self.headerSize...])) else { return nil }
        self.rolling = rolling
    }
}

/// The bigram composite-key encoding: `previous + US + next`, where US is the
/// ASCII unit separator (0x1F), a control byte no shell token contains, so the
/// key is unambiguous and reversible.
enum BigramKey {
    static let separator: Character = "\u{1F}"
    private static let separatorByte: UInt8 = 0x1F

    /// The composite key for a `(previous, next)` pair, or `nil` when the pair is
    /// unrecordable: either side empty, or either side carrying the separator byte
    /// (which would corrupt the encoding).
    static func compositeKey(previous: String, next: String) -> String? {
        guard !previous.isEmpty, !next.isEmpty,
              !previous.utf8.contains(separatorByte),
              !next.utf8.contains(separatorByte) else { return nil }
        return previous + String(separator) + next
    }
}

/// Adapts one previous token's slice of a composite-key ``CandidateSource`` into a
/// next-token source: queries `previous + US + prefix`, then strips the
/// `previous + US` lead off each composite key to recover the bare `next`.
struct NextTokenSource: CandidateSource {
    let base: any CandidateSource
    let previous: String

    func candidates(forPrefix prefix: String) -> [TokenCount] {
        let lead = previous + String(BigramKey.separator)
        // Strip the lead by byte count and decode the remainder: byte-consistent
        // with the module and immune to a leading combining mark a Character-wise
        // drop could mishandle.
        let dropBytes = lead.utf8.count
        return base.candidates(forPrefix: lead + prefix).map { candidate in
            let next = String(decoding: candidate.token.utf8.dropFirst(dropBytes), as: UTF8.self)
            return TokenCount(token: next, count: candidate.count)
        }
    }
}
