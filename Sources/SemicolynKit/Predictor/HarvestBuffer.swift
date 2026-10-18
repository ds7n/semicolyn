// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One batch of remote output handed to the screen-word harvest.
public struct HarvestChunk: Equatable, Sendable {
    /// The retained output bytes, oldest first.
    public let bytes: [UInt8]
    /// True when older bytes were dropped right before `bytes` (the buffer cap
    /// overflowed), so `bytes` may start mid-word or mid-escape-sequence and the
    /// harvest must not join it to what it saw before.
    public let droppedBefore: Bool

    public init(bytes: [UInt8], droppedBefore: Bool) {
        self.bytes = bytes
        self.droppedBefore = droppedBefore
    }
}

/// Coalesces remote output for the screen-word harvest so a large burst (a big
/// `cat`) costs bounded work and memory: bytes accumulate up to `capacity`, keeping
/// only the newest, and at most one harvest is in flight. The App appends every
/// output chunk, starts a harvest with ``takeIfIdle()``, and calls ``finish()``
/// when it completes, then takes again to drain what accumulated meanwhile. Pure.
public struct HarvestBuffer: Sendable {
    /// The default byte cap.
    public static let defaultCapacity = 8192

    /// Most bytes held between harvests; older bytes beyond it are dropped.
    public let capacity: Int
    private var pending: [UInt8] = []
    private var dropped = false
    /// True between a successful ``takeIfIdle()`` and the matching ``finish()``.
    public private(set) var inFlight = false

    public init(capacity: Int = HarvestBuffer.defaultCapacity) {
        precondition(capacity > 0, "harvest buffer capacity must be positive")
        self.capacity = capacity
    }

    /// Add output bytes. When the total exceeds `capacity`, the oldest bytes are
    /// dropped and the next chunk is flagged ``HarvestChunk/droppedBefore``.
    public mutating func append(_ bytes: [UInt8]) {
        if bytes.count >= capacity {
            if bytes.count > capacity || !pending.isEmpty { dropped = true }
            pending = Array(bytes.suffix(capacity))
            return
        }
        pending.append(contentsOf: bytes)
        let excess = pending.count - capacity
        guard excess > 0 else { return }
        pending.removeFirst(excess)
        dropped = true
    }

    /// The pending bytes as a chunk, marking a harvest in flight, or nil when one is
    /// already in flight or nothing is pending.
    public mutating func takeIfIdle() -> HarvestChunk? {
        guard !inFlight, !pending.isEmpty else { return nil }
        let chunk = HarvestChunk(bytes: pending, droppedBefore: dropped)
        pending = []
        pending.reserveCapacity(capacity)
        dropped = false
        inFlight = true
        return chunk
    }

    /// The in-flight harvest completed; the next ``takeIfIdle()`` may start one.
    public mutating func finish() {
        inFlight = false
    }

    /// Drop pending bytes and the in-flight mark (session teardown).
    public mutating func reset() {
        pending = []
        dropped = false
        inFlight = false
    }
}
