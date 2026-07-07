// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Ctrl arming state (function-keys spec, amended: tap=arm one-shot). The former
/// `.locked` state and its double-tap gesture were removed — the double-tap
/// recognizer forced SwiftUI to wait out the double-tap window before firing the
/// single-tap arm, which made touching Ctrl feel laggy (~0.5s). Ctrl is one-shot
/// only now; Alt/Shift already were.
public enum CtrlState: Equatable, Sendable { case off, armed }

/// The keybar's modifier arming state machine. Ctrl, Alt and Shift are all
/// one-shot only.
public struct ModifierState: Equatable, Sendable {
    public private(set) var ctrl: CtrlState = .off
    public private(set) var altArmed: Bool = false
    public private(set) var shiftArmed: Bool = false

    public init() {}

    /// Single tap on the Ctrl gesture: off→armed, armed→off (one-shot toggle).
    public mutating func tapCtrl() {
        switch ctrl {
        case .off:   ctrl = .armed
        case .armed: ctrl = .off
        }
    }

    /// Swipe-up arms Alt for one keystroke (no lock).
    public mutating func armAlt() { altArmed = true }

    /// Swipe-down arms Shift for one keystroke (no lock).
    public mutating func armShift() { shiftArmed = true }

    /// The modifiers to apply to the next keystroke.
    public func current() -> KeyModifiers {
        KeyModifiers(control: ctrl != .off, option: altArmed, shift: shiftArmed)
    }

    /// True when any modifier is armed or locked — i.e. a plain character typed on
    /// the terminal keyboard should be re-encoded through `encodeKey` rather than
    /// sent raw.
    public var hasArmedModifier: Bool { ctrl != .off || altArmed || shiftArmed }

    /// Clear one-shot arms after a keystroke fires.
    public mutating func consumeAfterKeystroke() {
        if ctrl == .armed { ctrl = .off }
        altArmed = false
        shiftArmed = false
    }
}
