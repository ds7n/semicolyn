// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Ctrl arming state (function-keys spec: tap=arm one-shot, double-tap=lock).
public enum CtrlState: Equatable, Sendable { case off, armed, locked }

/// The keybar's modifier arming state machine. Ctrl supports lock (Emacs-style
/// chord sequences); Alt and Shift are one-shot only (function-keys spec
/// "Companion change: Ctrl gets double-tap-to-lock").
public struct ModifierState: Equatable, Sendable {
    public private(set) var ctrl: CtrlState = .off
    public private(set) var altArmed: Bool = false
    public private(set) var shiftArmed: Bool = false

    public init() {}

    /// Single tap on the Ctrl gesture: off→armed, armed→off, locked→off (unlock).
    public mutating func tapCtrl() {
        switch ctrl {
        case .off:    ctrl = .armed
        case .armed:  ctrl = .off
        case .locked: ctrl = .off
        }
    }

    /// Double tap on the Ctrl gesture: lock until tapped off.
    public mutating func lockCtrl() { ctrl = .locked }

    /// Swipe-up arms Alt for one keystroke (no lock).
    public mutating func armAlt() { altArmed = true }

    /// Swipe-down arms Shift for one keystroke (no lock).
    public mutating func armShift() { shiftArmed = true }

    /// The modifiers to apply to the next keystroke.
    public func current() -> KeyModifiers {
        KeyModifiers(control: ctrl != .off, option: altArmed, shift: shiftArmed)
    }

    /// Clear one-shot arms after a keystroke fires; a Ctrl lock persists.
    public mutating func consumeAfterKeystroke() {
        if ctrl == .armed { ctrl = .off }
        altArmed = false
        shiftArmed = false
    }
}
