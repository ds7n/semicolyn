// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which rolling pre-aggregate to query.
public enum RollingWindow: Sendable {
    case days7, days30, days90

    /// The window length in days.
    public var days: Int {
        switch self {
        case .days7: return 7
        case .days30: return 30
        case .days90: return 90
        }
    }
}

/// The shared token index paired with one sketch, presented as a candidate
/// source. The lightweight adapter that lets a `RollingVocabulary` expose
/// `today` / `rolling_<window>` to the aggregate without duplicating the index.
struct IndexedSketch: CandidateSource {
    let index: PrefixIndex
    let counts: CountMinSketch
    func candidates(forPrefix prefix: String) -> [TokenCount] {
        index.matching(prefix: prefix).map { TokenCount(token: $0, count: counts.estimate($0)) }
    }
}

/// A vocabulary with daily time-windowing: a hot `today` sketch plus
/// `rolling_7d/30d/90d` pre-aggregates, over one shared token index. `record`
/// writes today; `rollover` (called at user-local midnight) seals today into the
/// rolling sums and evicts aged-out days; `learnedSource` exposes
/// `today ⊕ rolling_<window>` for ranking. See
/// `2026-06-21-predictor-daily-rollover-design`.
public struct RollingVocabulary: Equatable, Sendable {
    private var index: PrefixIndex
    private var today: CountMinSketch
    private var rolling7: CountMinSketch
    private var rolling30: CountMinSketch
    private var rolling90: CountMinSketch
    private var dailies: [CountMinSketch]   // sealed dailies, oldest first
    private let depth: Int
    private let width: Int

    /// The retention horizon — the largest window's reach; older dailies are
    /// pruned (no window can ever need them again).
    private static let retentionDays = 90

    /// A new windowed vocabulary whose sketches have the given dimensions
    /// (default: the spec's unigram `4 × 2^14`).
    public init(depth: Int = 4, width: Int = 1 << 14) {
        self.depth = depth
        self.width = width
        index = PrefixIndex()
        today = CountMinSketch(depth: depth, width: width)
        rolling7 = CountMinSketch(depth: depth, width: width)
        rolling30 = CountMinSketch(depth: depth, width: width)
        rolling90 = CountMinSketch(depth: depth, width: width)
        dailies = []
    }

    /// Learn `count` occurrences of `token` into today's sketch. Ignored for an
    /// empty token or zero count.
    public mutating func record(_ token: String, count: UInt32 = 1) {
        guard !token.isEmpty, count > 0 else { return }
        index.insert(token)
        today.add(token, count: count)
    }

    /// Seal today into the rolling pre-aggregates and start a fresh day. Each
    /// `rolling_W` gains today and loses the day that just fell out of its window,
    /// maintaining `rolling_W = sum of the most recent W sealed dailies`.
    public mutating func rollover() {
        let sealed = today
        dailies.append(sealed)
        let n = dailies.count

        rolling7.merge(sealed)
        if n > 7 { rolling7.subtract(dailies[n - 1 - 7]) }
        rolling30.merge(sealed)
        if n > 30 { rolling30.subtract(dailies[n - 1 - 30]) }
        rolling90.merge(sealed)
        if n > 90 { rolling90.subtract(dailies[n - 1 - 90]) }

        today = CountMinSketch(depth: depth, width: width)

        // Prune past the horizon — only after the subtracts, so the 90-day
        // window's evicted daily was still present above.
        if dailies.count > Self.retentionDays {
            dailies.removeFirst(dailies.count - Self.retentionDays)
        }
    }

    /// `today ⊕ rolling_<window>` as a candidate source for ranking.
    public func learnedSource(window: RollingWindow) -> AggregateCandidateSource {
        let rolling: CountMinSketch
        switch window {
        case .days7: rolling = rolling7
        case .days30: rolling = rolling30
        case .days90: rolling = rolling90
        }
        return AggregateCandidateSource([
            IndexedSketch(index: index, counts: today),
            IndexedSketch(index: index, counts: rolling),
        ])
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x52, 0x4c, 0x56]  // "GRLV"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    /// Serialize the whole windowed state: `magic | version | index | today |
    /// rolling7 | rolling30 | rolling90 | dailyCount | dailies…`, each sub-blob
    /// length-prefixed.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendSubBlob(&out, index.serialize())
        appendSubBlob(&out, today.serialize())
        appendSubBlob(&out, rolling7.serialize())
        appendSubBlob(&out, rolling30.serialize())
        appendSubBlob(&out, rolling90.serialize())
        appendLE32(&out, UInt32(dailies.count))
        for daily in dailies { appendSubBlob(&out, daily.serialize()) }
        return out
    }

    /// Reconstruct the whole state. Fails closed (`nil`) on wrong magic/version, a
    /// rejected sub-blob, trailing slack, or any sketch whose dimensions differ
    /// from `today`'s — mixed dimensions would make the rollover merge/subtract a
    /// silent no-op, so such a blob is rejected outright. `depth`/`width` are taken
    /// from `today` (a CMS carries its own dimensions).
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion else { return nil }

        var p = Self.headerSize
        guard let indexBlob = readLengthPrefixed(bytes, &p),
              let index = PrefixIndex(deserializing: indexBlob),
              let today = readSketch(bytes, &p),
              let rolling7 = readSketch(bytes, &p),
              let rolling30 = readSketch(bytes, &p),
              let rolling90 = readSketch(bytes, &p),
              let rawDailyCount = readLE32(bytes, p) else { return nil }
        p += 4

        var dailies: [CountMinSketch] = []
        for _ in 0..<Int(rawDailyCount) {
            guard let daily = readSketch(bytes, &p) else { return nil }
            dailies.append(daily)
        }
        guard p == bytes.count else { return nil }   // no trailing slack
        // A real serialized state is pruned to the retention horizon; more dailies
        // than that is a malformed/hostile blob (and an unbounded resource).
        guard dailies.count <= Self.retentionDays else { return nil }

        // All sketches must share today's dimensions or rollover arithmetic breaks.
        let depth = today.depth, width = today.width
        let sameDimensions = { (s: CountMinSketch) in s.depth == depth && s.width == width }
        guard sameDimensions(rolling7), sameDimensions(rolling30), sameDimensions(rolling90),
              dailies.allSatisfy(sameDimensions) else { return nil }

        self.index = index
        self.today = today
        self.rolling7 = rolling7
        self.rolling30 = rolling30
        self.rolling90 = rolling90
        self.dailies = dailies
        self.depth = depth
        self.width = width
    }
}

/// Append a length-prefixed sub-blob (`LE32 length | bytes`) — the write-side
/// counterpart to `readLengthPrefixed`, shared by the composite serializers.
func appendSubBlob(_ out: inout [UInt8], _ blob: [UInt8]) {
    appendLE32(&out, UInt32(blob.count))
    out.append(contentsOf: blob)
}

/// Read a length-prefixed ``CountMinSketch`` sub-blob at `p`, advancing it; `nil`
/// if the length overruns the buffer or the sketch blob is rejected.
private func readSketch(_ bytes: [UInt8], _ p: inout Int) -> CountMinSketch? {
    guard let blob = readLengthPrefixed(bytes, &p) else { return nil }
    return CountMinSketch(deserializing: blob)
}
