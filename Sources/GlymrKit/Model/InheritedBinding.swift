// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Pure conversion helpers for bridging `Inherited<T>` fields to and from plain
/// `String` values used in text-field bindings.
///
/// Rules for `Inherited<String>`:
/// - Empty string → `.inherit` (field is absent; UI shows a resolved hint).
/// - Non-empty string → `.explicit(string)`.
///
/// Rules for `Inherited<Int>`:
/// - Empty string → `.inherit`.
/// - Non-numeric string → `.inherit` (silently ignored; callers validate elsewhere).
/// - Numeric string → `.explicit(int)`.
///
/// These functions are pure and have no SwiftUI dependency so they can be
/// exercised on Linux via `GlymrKitTests`.

// MARK: - Inherited<String>

/// Converts an `Inherited<String>` to the text-field string.
/// `.inherit` and `.explicit(nil)` both yield an empty string (field is blank).
/// `.explicit(value)` yields the string itself.
public func inheritedStringToText(_ inherited: Inherited<String>) -> String {
    inherited.value ?? ""
}

/// Converts a text-field string back to `Inherited<String>`.
/// Empty string → `.inherit`. Non-empty → `.explicit(text)`.
public func textToInheritedString(_ text: String) -> Inherited<String> {
    text.isEmpty ? .inherit : .explicit(text)
}

// MARK: - Inherited<Int>

/// Converts an `Inherited<Int>` to the text-field string.
/// `.inherit` and `.explicit(nil)` yield an empty string.
/// `.explicit(n)` yields `String(n)`.
public func inheritedIntToText(_ inherited: Inherited<Int>) -> String {
    inherited.value.map { String($0) } ?? ""
}

/// Converts a text-field string back to `Inherited<Int>`.
/// Empty string → `.inherit`. Non-numeric or negative string → `.inherit`.
/// Valid positive integer string → `.explicit(int)`.
public func textToInheritedInt(_ text: String) -> Inherited<Int> {
    guard !text.isEmpty, let n = Int(text), n > 0 else { return .inherit }
    return .explicit(n)
}
