// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The shared token index paired with one sketch, presented as a candidate
/// source. Counts are the sketch's `Float` estimates rounded up (see
/// ``roundedUpCount(_:)``), so a faded-but-unpruned literal still counts as 1.
struct IndexedSketch: CandidateSource {
    let index: PrefixIndex
    let counts: CountMinSketch
    func candidates(forPrefix prefix: String) -> [TokenCount] {
        index.matching(prefix: prefix).map { TokenCount(token: $0, count: roundedUpCount(counts.estimate($0))) }
    }
}

/// The user's learned vocabulary: one frequency sketch over one prefix index of
/// the literals that may be suggested. `record` adds to the sketch (and the index,
/// unless count-only); `scale(by:)` fades every count; `pruneLiterals(below:)` and
/// `capLiterals(max:target:)` drop faded or excess literals so the store forgets
/// with use. See `2026-11-08-predictor-learned-fade-design`.
public struct LearnedVocabulary: Equatable, Sendable {
    private var index: PrefixIndex
    private var sketch: CountMinSketch

    /// A new, empty vocabulary whose sketch has the given dimensions (default:
    /// the spec's unigram `4 × 2^14`).
    public init(depth: Int = 4, width: Int = 1 << 14) {
        index = PrefixIndex()
        sketch = CountMinSketch(depth: depth, width: width)
    }

    /// Learn `count` occurrences of `token`. When `storeLiteral` is false (L7
    /// low-confidence) the literal is withheld from the prefix index: the count
    /// still contributes to frequency, but the token can never be surfaced as a
    /// completion or reconstructed from disk. Ignored for empty token / zero count.
    public mutating func record(_ token: String, count: UInt32 = 1, storeLiteral: Bool = true) {
        guard !token.isEmpty, count > 0 else { return }
        if storeLiteral { index.insert(token) }
        sketch.add(token, count: Float(count))
    }

    /// True when `token` is stored as a literal (exact UTF-8 byte match). A token
    /// recorded count-only (`storeLiteral: false`) is never reported.
    public func containsLiteral(_ token: String) -> Bool {
        index.contains(token)
    }

    /// Number of stored literals (count-only tokens are not counted).
    public var literalCount: Int { index.count }

    /// The raw sketch estimate for `token` (literal or count-only).
    func estimate(_ token: String) -> Float {
        sketch.estimate(token)
    }

    /// The learned literals with their (rounded-up) counts, as a candidate source
    /// for ranking.
    public func learnedSource() -> AggregateCandidateSource {
        AggregateCandidateSource([IndexedSketch(index: index, counts: sketch)])
    }

    /// A representative high-frequency magnitude: the ~90th percentile of all
    /// literal counts (nearest rank). Used to normalize the learned source onto
    /// the same scale as the seeds before blending. Returns 0 for an empty
    /// vocabulary.
    public func magnitude() -> UInt32 {
        let tokens = index.matching(prefix: "")
        guard !tokens.isEmpty else { return 0 }
        let estimates = tokens.map { roundedUpCount(sketch.estimate($0)) }.sorted()
        let idx = min(estimates.count - 1, Int((Double(estimates.count) * 0.9).rounded(.down)))
        return estimates[idx]
    }

    /// Multiply every sketch cell by `factor` (the fade step). Literals are kept;
    /// follow with ``pruneLiterals(below:)`` to drop the ones that faded out.
    public mutating func scale(by factor: Float) {
        sketch.scale(by: factor)
    }

    /// Remove every literal whose estimate is strictly below `threshold`. The
    /// sketch is untouched (its counts keep fading). Returns the number removed.
    @discardableResult
    public mutating func pruneLiterals(below threshold: Float) -> Int {
        let sketch = self.sketch
        return index.removeAll { sketch.estimate($0) < threshold }
    }

    /// When more than `max` literals are held, remove the lowest-estimate ones
    /// until exactly `target` remain (equal estimates: the byte-smaller literal
    /// goes first, so the result is deterministic). A no-op at or below `max`.
    /// Returns the number removed.
    @discardableResult
    public mutating func capLiterals(max: Int, target: Int) -> Int {
        guard index.count > max else { return 0 }
        let excess = index.count - Swift.max(0, target)
        guard excess > 0 else { return 0 }
        // `matching("")` is byte-sorted; breaking ties on that offset keeps byte order.
        let ranked = index.matching(prefix: "")
            .map { (token: $0, estimate: sketch.estimate($0)) }
            .enumerated()
            .sorted { $0.element.estimate != $1.element.estimate
                ? $0.element.estimate < $1.element.estimate : $0.offset < $1.offset }
        let doomed = Set(ranked.prefix(excess).map(\.element.token))
        return index.removeAll { doomed.contains($0) }
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x4c, 0x56, 0x43]  // "GLVC"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    /// Serialize: `magic | version | index | sketch`, each sub-blob length-prefixed.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendSubBlob(&out, index.serialize())
        appendSubBlob(&out, sketch.serialize())
        return out
    }

    /// Reconstruct a vocabulary of the given dimensions (default: the unigram
    /// `4 × 2^14`). Fails closed (`nil`) on wrong magic/version, a rejected
    /// sub-blob, trailing slack, or a sketch whose dimensions differ from
    /// `depth` × `width` (a foreign-sized sketch would not merge or compare with
    /// the store it is meant to be).
    public init?(deserializing bytes: [UInt8], depth: Int = 4, width: Int = 1 << 14) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion else { return nil }
        var p = Self.headerSize
        guard let indexBlob = readLengthPrefixed(bytes, &p),
              let index = PrefixIndex(deserializing: indexBlob),
              let sketch = readSketch(bytes, &p),
              p == bytes.count,                                   // no trailing slack
              sketch.depth == depth, sketch.width == width else { return nil }
        self.index = index
        self.sketch = sketch
    }
}

/// A `Float` estimate as a `UInt32` count, rounded up (so any positive estimate
/// counts at least 1) and clamped at `UInt32.max`.
func roundedUpCount(_ estimate: Float) -> UInt32 {
    // Float(UInt32.max) rounds up to 2^32, which would trap in UInt32(_:).
    estimate >= Float(UInt32.max) ? .max : UInt32(estimate.rounded(.up))
}

/// Append a length-prefixed sub-blob (`LE32 length | bytes`), the write-side
/// counterpart to `readLengthPrefixed`, shared by the composite serializers.
func appendSubBlob(_ out: inout [UInt8], _ blob: [UInt8]) {
    appendLE32(&out, UInt32(blob.count))
    out.append(contentsOf: blob)
}

/// Read a length-prefixed ``CountMinSketch`` sub-blob at `p`, advancing it; `nil`
/// if the length overruns the buffer or the sketch blob is rejected.
func readSketch(_ bytes: [UInt8], _ p: inout Int) -> CountMinSketch? {
    guard let blob = readLengthPrefixed(bytes, &p) else { return nil }
    return CountMinSketch(deserializing: blob)
}
