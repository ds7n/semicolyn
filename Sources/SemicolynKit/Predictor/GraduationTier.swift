// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One occurrence to persist into the learned store when a token graduates (or,
/// post-graduation, passes straight through). Mirrors the `record(token, count,
/// after: previous)` shape the engine already uses.
public struct GraduatedOccurrence: Equatable, Hashable, Sendable {
    public let token: String
    public let previous: String?
    public let count: UInt32
    public init(token: String, previous: String?, count: UInt32) {
        self.token = token; self.previous = previous; self.count = count
    }
}

/// L6 frequency-graduation tier (pure, ephemeral, never persisted). A token does
/// not enter the persistent learned vocabulary on first sight: it must recur across
/// ≥ `threshold` DISTINCT preceding-token contexts, OR be typed ≥ `threshold` times
/// at start-of-line (`previous == nil`), first. A password typed at a prompt has a
/// non-nil preceding word, so it needs N *distinct* contexts → a once/few-typed
/// password (even a low-entropy human one L5 can't match) never graduates; a bare
/// command repeated at the prompt graduates via the nil count (utility).
///
/// On graduation the accumulated pre-graduation occurrences are BACKFILLED (returned
/// all at once) so frequency ranking reflects the true history. Bounded by
/// `maxTracked` (oldest-pending eviction) so a long/hostile session can't grow it
/// unboundedly; eviction only ever DELAYS learning (safe).
public struct GraduationTier: Equatable, Sendable {
    /// Tokens that have crossed the threshold — record directly, no deferral.
    private var graduated: Set<String> = []
    /// Un-graduated tokens → their distinct `previous` contexts → accumulated count.
    private var pending: [String: [String?: UInt32]] = [:]
    /// Insertion order of pending token keys, for oldest-first eviction.
    private var pendingOrder: [String] = []
    private let threshold: Int
    private let maxTracked: Int

    public init(threshold: Int = 3, maxTracked: Int = 4096) {
        self.threshold = max(1, threshold)
        self.maxTracked = max(1, maxTracked)
    }

    /// Admit one observed occurrence. Returns the occurrences to persist NOW: empty
    /// while the token is still deferred; on the graduating call, every accumulated
    /// occurrence (backfill); post-graduation, just this occurrence.
    public mutating func admit(token: String, previous: String?, count: UInt32) -> [GraduatedOccurrence] {
        if graduated.contains(token) {
            return [GraduatedOccurrence(token: token, previous: previous, count: count)]
        }
        if pending[token] == nil {
            evictIfNeeded()
            pending[token] = [:]
            pendingOrder.append(token)
        }
        pending[token]![previous, default: 0] += count

        let contexts = pending[token]!
        // Combined predicate: ≥N distinct preceding tokens, OR ≥N start-of-line
        // (nil) occurrences. A bare command repeated at the prompt graduates via the
        // nil count; a prompt-secret (non-nil preceding word) needs N distinct
        // contexts and so a once/few-typed password never graduates.
        let graduates = contexts.count >= threshold || (contexts[nil] ?? 0) >= UInt32(threshold)
        guard graduates else { return [] }
        // Graduate: flush the backfill, promote, drop from pending.
        let flushed = contexts.map { GraduatedOccurrence(token: token, previous: $0.key, count: $0.value) }
        graduated.insert(token)
        pending[token] = nil
        pendingOrder.removeAll { $0 == token }
        return flushed
    }

    /// Clear all ephemeral state (context/incognito/host switch). Graduated tokens
    /// are also forgotten — this is a session-scoped tier; the persistent store holds
    /// what already graduated.
    public mutating func reset() {
        graduated.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
    }

    /// Evict the oldest pending token if at capacity, to bound memory. Only delays
    /// learning for the evicted token (safe).
    private mutating func evictIfNeeded() {
        guard pending.count >= maxTracked, let oldest = pendingOrder.first else { return }
        pending[oldest] = nil
        pendingOrder.removeFirst()
    }
}
