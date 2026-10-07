// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How to bring the software keyboard (and the keybar riding on it as the terminal's
/// `inputAccessoryView`) back on screen.
public enum KeyboardRestoreAction: Equatable, Sendable {
    /// Keyboard already showing: leave it alone (the tap belongs to the terminal).
    case none
    /// The terminal lost focus: reclaim it, which presents the keyboard.
    case becomeFirstResponder
    /// The terminal still HAS focus but the keyboard is hidden (e.g. a sheet presented from
    /// the keybar hides it without resigning). `becomeFirstResponder` is a no-op here, and a
    /// resign+become bounce collapses the keybar layout (device build 136), so re-present the
    /// input views in place.
    case reloadInputViews
}

/// Decide how to restore the keyboard from the terminal's focus state and whether the
/// keyboard (its input accessory) is currently attached to a window.
public func keyboardRestoreAction(isFirstResponder: Bool, keyboardVisible: Bool) -> KeyboardRestoreAction {
    guard isFirstResponder else { return .becomeFirstResponder }
    return keyboardVisible ? .none : .reloadInputViews
}
