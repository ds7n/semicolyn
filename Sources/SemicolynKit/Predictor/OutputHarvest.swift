// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A short-lived, bounded store of tokens harvested from command *output*
/// (filenames, pod names, branch names…), so they surface as one-tap completions
/// when the user types a matching prefix. Recency-ordered and capacity-bounded —
/// new output pushes old output out — which models "short-lived" deterministically
/// without a clock. Ephemeral: never persisted. A ``CandidateSource`` whose
/// natural ranking is recency. See `2026-06-21-predictor-output-harvesting-design`.
public struct OutputHarvest: CandidateSource {
    private var order: [String]   // distinct tokens, oldest → newest
    private let capacity: Int

    public init(capacity: Int = 200) {
        precondition(capacity > 0, "harvest capacity must be positive")
        self.order = []
        self.order.reserveCapacity(capacity)
        self.capacity = capacity
    }

    /// Harvest one output token as the most-recent. A repeat (same bytes) moves to
    /// most-recent rather than duplicating; an empty token is ignored. Evicts the
    /// oldest when over capacity.
    public mutating func harvest(_ token: String) {
        guard !token.isEmpty else { return }
        if let i = order.firstIndex(where: { $0.utf8.elementsEqual(token.utf8) }) {
            order.remove(at: i)
        }
        order.append(token)
        if order.count > capacity { order.removeFirst(order.count - capacity) }
    }

    /// Harvest a sequence of output tokens in order; the last becomes most-recent.
    public mutating func harvest(_ tokens: [String]) {
        for token in tokens { harvest(token) }
    }

    /// Drop all harvested tokens — for a context change (host switch, incognito).
    public mutating func clear() {
        order.removeAll(keepingCapacity: true)
    }

    /// Tokens having `prefix` (by UTF-8 bytes), **newest first**, each carrying its
    /// recency position as `count` (newer → higher) so any count-ranking consumer
    /// orders by recency. Empty prefix matches all.
    public func candidates(forPrefix prefix: String) -> [TokenCount] {
        let prefixBytes = Array(prefix.utf8)
        var result: [TokenCount] = []
        var i = order.count - 1
        while i >= 0 {
            let token = order[i]
            if prefixBytes.isEmpty || token.utf8.starts(with: prefixBytes) {
                result.append(TokenCount(token: token, count: UInt32(clamping: i + 1)))
            }
            i -= 1
        }
        return result
    }
}
