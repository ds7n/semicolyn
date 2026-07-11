// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Per-pane ordering state machine for tmux -CC history seeding. Ensures a pane's
/// captured history is fed to the terminal BEFORE any live `%output`, and that live
/// output racing the capture response is buffered and replayed in order after it.
///
/// Lifecycle: `.unseeded` → `beginSeeding()` → `.seeding` → `completeSeed(history:)`
/// → `.seeded`. `resync()` (on `%pause`/reconnect/resize) returns to `.unseeded` and
/// drops the buffer so a fresh capture reseeds cleanly.
public struct PaneSeedState: Equatable, Sendable {
    private enum Phase: Equatable { case unseeded, seeding, seeded }
    private var phase: Phase = .unseeded
    private var pending: [UInt8] = []

    public init() {}

    /// True while a capture is still needed (`.unseeded`). The seeder issues a
    /// `capture-pane` when this is true and then calls `beginSeeding()`.
    public var needsSeed: Bool { phase == .unseeded }

    /// Mark that a capture has been issued. Idempotent while already seeding.
    public mutating func beginSeeding() {
        if phase == .unseeded { phase = .seeding }
    }

    /// Route live pane output. Buffers (returns `[]`) until the pane is seeded; once
    /// seeded, returns the bytes for immediate feed.
    public mutating func onOutput(_ bytes: [UInt8]) -> [UInt8] {
        switch phase {
        case .seeded:
            return bytes
        case .unseeded, .seeding:
            pending.append(contentsOf: bytes)
            return []
        }
    }

    /// Complete the seed: returns `history` followed by all buffered output in arrival
    /// order (the caller clears scrollback, then feeds this), and clears the buffer.
    public mutating func completeSeed(history: [UInt8]) -> [UInt8] {
        let flush = history + pending
        pending.removeAll()
        phase = .seeded
        return flush
    }

    /// Return to `.unseeded` (a resync trigger). Drops any buffered output; the next
    /// capture reseeds from scratch.
    public mutating func resync() {
        phase = .unseeded
        pending.removeAll()
    }
}
