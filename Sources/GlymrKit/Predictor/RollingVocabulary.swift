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
public struct RollingVocabulary {
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
}
