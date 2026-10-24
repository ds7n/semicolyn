// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Fn-layer state (function-keys spec): caps-lock semantics.
public enum FnMode: Equatable, Sendable { case off, armed, locked }

public struct FnState: Equatable, Sendable {
    public private(set) var mode: FnMode = .off

    public init() {}

    /// True when F-keys should be shown (Armed or Locked).
    public var engaged: Bool { mode != .off }

    /// Single tap: off->armed, armed->locked, locked->off.
    ///
    /// The former `doubleTap()` (manual lock in one gesture) was removed with the
    /// keybar double-tap recognizer; the tap cycle is now the only path to lock.
    public mutating func tap() {
        switch mode {
        case .off:    mode = .armed
        case .armed:  mode = .locked
        case .locked: mode = .off
        }
    }

    /// An F-key fired: clears a one-shot arm; a lock persists.
    public mutating func fireFKey() { if mode == .armed { mode = .off } }

    /// Full reset (e.g. the session changed): back to off.
    public mutating func reset() { mode = .off }
}
