// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Next-token prediction with daily time-windowing: a hot `today` plus
/// `rolling_7d/30d/90d` pre-aggregates over `(previous, next)` adjacencies.
/// `record` writes today; `rollover` (called at user-local midnight) seals today
/// and slides each window; `nextSource(after:window:)` exposes a previous token's
/// successors as `today ⊕ rolling_W`. A windowed bigram is a windowed unigram over
/// the composite key `previous + US + next`, so this wraps ``RollingVocabulary``
/// exactly as ``BigramVocabulary`` wraps ``Vocabulary``. See
/// `2026-06-21-predictor-bigram-rollover-design`.
public struct RollingBigramVocabulary: Equatable, Sendable {
    private var rolling: RollingVocabulary

    /// A new windowed bigram store whose composite-key sketches have the given
    /// dimensions (default: the spec's bigram `4 × 2^16`, matching
    /// ``BigramVocabulary``).
    public init(depth: Int = 4, width: Int = 1 << 16) {
        rolling = RollingVocabulary(depth: depth, width: width)
    }

    /// Learn `count` occurrences of `next` following `previous` into today's
    /// sketch. Ignored when the pair is unrecordable
    /// (see ``BigramVocabulary/compositeKey(previous:next:)``) or `count` is zero.
    public mutating func record(previous: String, next: String, count: UInt32 = 1) {
        guard count > 0,
              let key = BigramVocabulary.compositeKey(previous: previous, next: next) else { return }
        rolling.record(key, count: count)
    }

    /// Seal today into the rolling pre-aggregates and start a fresh day —
    /// inherited verbatim from ``RollingVocabulary`` (the composite key is just a
    /// string to the rollover arithmetic).
    public mutating func rollover() {
        rolling.rollover()
    }

    /// A ``CandidateSource`` of `previous`'s successors over `today ⊕ rolling_W`,
    /// next tokens decoded to bare strings — plugs straight into
    /// ``SeededSuggester``.
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
