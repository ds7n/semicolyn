// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Next-token prediction over `(previous, next)` adjacencies: one sketch plus one
/// prefix index over the composite key `previous + US + next` (``BigramKey``), so
/// this wraps a ``LearnedVocabulary``. `nextSource(after:)` exposes a previous
/// token's successors; `scale`, `pruneLiterals(below:)` and
/// `capLiterals(max:target:)` fade and bound it like the unigram store. See
/// `2026-11-08-predictor-learned-fade-design`.
public struct LearnedBigramVocabulary: Equatable, Sendable {
    private var vocabulary: LearnedVocabulary

    /// A new, empty bigram store whose composite-key sketch has the given
    /// dimensions (default: the spec's bigram `4 × 2^16`, wider than the unigram
    /// table because the `(previous, next)` pair space is larger).
    public init(depth: Int = 4, width: Int = 1 << 16) {
        vocabulary = LearnedVocabulary(depth: depth, width: width)
    }

    /// A bigram store over an existing composite-key vocabulary (the legacy-file
    /// migration).
    init(vocabulary: LearnedVocabulary) {
        self.vocabulary = vocabulary
    }

    /// Learn `count` occurrences of `next` following `previous`. Ignored when the
    /// pair is unrecordable (see ``BigramKey/compositeKey(previous:next:)``) or
    /// `count` is zero.
    public mutating func record(previous: String, next: String, count: UInt32 = 1,
                                storeLiteral: Bool = true) {
        guard count > 0,
              let key = BigramKey.compositeKey(previous: previous, next: next) else { return }
        vocabulary.record(key, count: count, storeLiteral: storeLiteral)
    }

    /// Number of stored pair literals (count-only pairs are not counted).
    public var literalCount: Int { vocabulary.literalCount }

    /// A ``CandidateSource`` of `previous`'s successors, next tokens decoded to
    /// bare strings, for the ranker's next-word mode.
    public func nextSource(after previous: String) -> any CandidateSource {
        NextTokenSource(base: vocabulary.learnedSource(), previous: previous)
    }

    /// Successors of `previous` having `prefix`, byte-sorted with estimated counts,
    /// sugar over `nextSource(after:)`. Empty `prefix` (the default) returns every
    /// known successor.
    public func candidates(after previous: String, prefix: String = "") -> [TokenCount] {
        nextSource(after: previous).candidates(forPrefix: prefix)
    }

    /// Multiply every sketch cell by `factor` (the fade step).
    public mutating func scale(by factor: Float) {
        vocabulary.scale(by: factor)
    }

    /// Remove every pair literal whose estimate is strictly below `threshold`.
    /// Returns the number removed.
    @discardableResult
    public mutating func pruneLiterals(below threshold: Float) -> Int {
        vocabulary.pruneLiterals(below: threshold)
    }

    /// When more than `max` pair literals are held, remove the lowest-estimate
    /// ones until exactly `target` remain (ties by composite-key byte order).
    /// Returns the number removed.
    @discardableResult
    public mutating func capLiterals(max: Int, target: Int) -> Int {
        vocabulary.capLiterals(max: max, target: target)
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x4c, 0x42, 0x47]  // "GLBG"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    /// Serialize: `magic | version | inner LearnedVocabulary blob`. The distinct
    /// magic guards against loading a unigram `GLVC` state as a bigram store.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        out.append(contentsOf: vocabulary.serialize())
        return out
    }

    /// Reconstruct a bigram store of the given dimensions (default `4 × 2^16`).
    /// Fails closed (`nil`) on wrong magic/version or if the inner vocabulary is
    /// rejected (which already forbids trailing slack and mismatched dimensions,
    /// so the rest-of-bytes payload needs no length prefix).
    public init?(deserializing bytes: [UInt8], depth: Int = 4, width: Int = 1 << 16) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let vocabulary = LearnedVocabulary(deserializing: Array(bytes[Self.headerSize...]),
                                                 depth: depth, width: width) else { return nil }
        self.vocabulary = vocabulary
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
