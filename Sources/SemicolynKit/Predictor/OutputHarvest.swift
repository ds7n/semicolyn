// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A short-lived, bounded store of tokens harvested from command *output*
/// (filenames, pod names, branch names…), so they surface as one-tap completions
/// when the user types a matching prefix. Recency-ordered and capacity-bounded,
/// new output pushes old output out, which models "short-lived" deterministically
/// without a clock. Ephemeral: never persisted. A ``CandidateSource`` whose
/// natural ranking is recency. See `2026-06-21-predictor-output-harvesting-design`.
public struct OutputHarvest: CandidateSource, Sendable {
    /// Harvest slots, oldest to newest. A nil slot is a token that later moved to
    /// newest or was evicted; live slots in order are the recency order. Slots
    /// before `head` are all nil.
    private var slots: [String?]
    private var head: Int
    /// Live token (by UTF-8 bytes) to its slot: the O(1) duplicate check.
    private var slotOf: [[UInt8]: Int]
    private let capacity: Int

    public init(capacity: Int = 200) {
        precondition(capacity > 0, "harvest capacity must be positive")
        self.slots = []
        self.slots.reserveCapacity(capacity * 2)
        self.head = 0
        self.slotOf = Dictionary(minimumCapacity: capacity + 1)
        self.capacity = capacity
    }

    /// Harvest one output token as the most-recent. A repeat (same bytes) moves to
    /// most-recent rather than duplicating; an empty token is ignored. Evicts the
    /// oldest when over capacity. Amortized O(1).
    public mutating func harvest(_ token: String) {
        guard !token.isEmpty else { return }
        let key = Array(token.utf8)
        if let i = slotOf[key] { slots[i] = nil }
        slots.append(token)
        slotOf[key] = slots.count - 1
        if slotOf.count > capacity { evictOldest() }
        if slots.count > capacity * 2 { compact() }
    }

    /// Harvest a sequence of output tokens in order; the last becomes most-recent.
    public mutating func harvest(_ tokens: [String]) {
        for token in tokens { harvest(token) }
    }

    /// Drop all harvested tokens, for a context change (host switch, incognito).
    public mutating func clear() {
        slots.removeAll(keepingCapacity: true)
        slotOf.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Tokens having `prefix` (by UTF-8 bytes), **newest first**, each carrying its
    /// recency position as `count` (newer → higher) so any count-ranking consumer
    /// orders by recency. Empty prefix matches all.
    public func candidates(forPrefix prefix: String) -> [TokenCount] {
        let prefixBytes = Array(prefix.utf8)
        var result: [TokenCount] = []
        var position = slotOf.count            // recency position of the next live slot
        var i = slots.count - 1
        while i >= head {
            defer { i -= 1 }
            guard let token = slots[i] else { continue }
            if prefixBytes.isEmpty || token.utf8.starts(with: prefixBytes) {
                result.append(TokenCount(token: token, count: UInt32(clamping: position)))
            }
            position -= 1
        }
        return result
    }

    /// Drop the oldest live token.
    private mutating func evictOldest() {
        while head < slots.count {
            defer { head += 1 }
            guard let token = slots[head] else { continue }
            slots[head] = nil
            slotOf[Array(token.utf8)] = nil
            return
        }
    }

    /// Rebuild the slots without holes so their count stays within twice the
    /// capacity (keeps `harvest` amortized O(1) and memory bounded).
    private mutating func compact() {
        let live = slots[head...].compactMap { $0 }
        slots.removeAll(keepingCapacity: true)
        slots.append(contentsOf: live.map { Optional($0) })
        head = 0
        for (i, token) in live.enumerated() { slotOf[Array(token.utf8)] = i }
    }
}

/// Whether `token` can be a word harvested from screen output: 3 to 64 characters
/// from `[A-Za-z0-9._/~-]` with at least one letter. This drops prompt glyphs,
/// box-drawing, bare numbers and long blobs before any secret filtering.
public func isScreenWordShaped(_ token: String) -> Bool {
    let bytes = token.utf8
    guard (3...64).contains(bytes.count) else { return false }
    var sawLetter = false
    for b in bytes {
        switch b {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
            sawLetter = true
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "~"), UInt8(ascii: "-"):
            break
        default:
            return false
        }
    }
    return sawLetter
}
