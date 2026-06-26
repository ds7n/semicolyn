// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Fn-layer state (function-keys spec). Caps-lock semantics plus context
/// auto-engage with a per-episode user override.
public enum FnMode: Equatable, Sendable { case off, armed, locked }

public struct FnState: Equatable, Sendable {
    public private(set) var mode: FnMode = .off
    /// The active pane is currently in an auto-Fn context (htop/top/mc).
    private var autoActive = false
    /// The user dismissed Fn during the current auto episode → don't re-lock.
    private var userOverride = false
    /// The current lock was established by `autoEngage()` (not a manual lock).
    private var autoLocked = false

    public init() {}

    /// True when F-keys should be shown (Armed or Locked).
    public var engaged: Bool { mode != .off }

    /// Single tap: off→armed, armed→locked, locked→off. Turning a locked Fn off
    /// while a context auto-engaged it sets the per-episode override.
    public mutating func tap() {
        switch mode {
        case .off:    mode = .armed
        case .armed:  mode = .locked; autoLocked = false      // manual lock via 2nd tap
        case .locked:
            mode = .off
            if autoActive && autoLocked { userOverride = true }
            autoLocked = false
        }
    }

    /// Double tap: manual lock. Clears any standing override.
    public mutating func doubleTap() { mode = .locked; userOverride = false; autoLocked = false }

    /// An F-key fired: clears a one-shot arm; a lock persists.
    public mutating func fireFKey() { if mode == .armed { mode = .off } }

    /// Context entered an auto-Fn process: lock unless the user overrode this episode.
    public mutating func autoEngage() {
        autoActive = true
        if !userOverride { mode = .locked; autoLocked = true }
    }

    /// Context left the auto-Fn process: end the episode and return to off. A
    /// no-op when no auto-episode is active, so a manually-armed/locked Fn (toggled
    /// by the user in a non-auto context) is never clobbered by routine polls.
    public mutating func autoDisengage() {
        guard autoActive else { return }
        autoActive = false
        userOverride = false
        autoLocked = false
        mode = .off
    }

    /// Full reset (e.g. the focused pane changed): clears mode + episode state.
    public mutating func reset() { mode = .off; autoActive = false; userOverride = false; autoLocked = false }
}
