// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Pure conversion helpers for bridging `Inherited<T>` fields to and from plain
/// `String` values used in text-field bindings, and to/from Picker-compatible
/// optional-enum selections used in three-state Picker bindings.
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
/// Rules for `Inherited<Bool>` ↔ `Bool?` (Picker selection):
/// - `.inherit` → `nil` (tag labelled "Default").
/// - `.explicit(true)` → `true`.
/// - `.explicit(false)` → `false`.
/// - `.explicit(nil)` → `nil` (treated as inherit for Picker purposes).
///
/// Rules for `Inherited<StrictHostKeyChecking>` ↔ `StrictHostKeyChecking?`:
/// - `.inherit` → `nil` (tag labelled "Default").
/// - `.explicit(v)` → `v`.
/// - `.explicit(nil)` → `nil`.
///
/// Rules for `Inherited<[AuthMethod]>` ↔ `Set<AuthMethod>?`:
/// - `.inherit` → `nil` (unselected, meaning "use default").
/// - `.explicit(methods)` → `Set(methods)`.
/// - `.explicit(nil)` → `nil`.
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

// MARK: - Inherited<Bool>

/// Converts `Inherited<Bool>` to a `Bool?` for use as a Picker selection tag.
/// `.inherit` and `.explicit(nil)` → `nil` ("Default" option).
/// `.explicit(true)` → `true`; `.explicit(false)` → `false`.
/// `.explicit(nil)` has no distinct Picker representation and collapses to `.inherit` on round-trip — intentional.
public func inheritedBoolToSelection(_ inherited: Inherited<Bool>) -> Bool? {
    inherited.value
}

/// Converts a `Bool?` Picker selection back to `Inherited<Bool>`.
/// `nil` → `.inherit`; `true`/`false` → `.explicit(value)`.
public func selectionToInheritedBool(_ selection: Bool?) -> Inherited<Bool> {
    guard let v = selection else { return .inherit }
    return .explicit(v)
}

// MARK: - Inherited<StrictHostKeyChecking>

/// Converts `Inherited<StrictHostKeyChecking>` to a `StrictHostKeyChecking?`
/// for use as a Picker selection tag.
/// `.inherit` and `.explicit(nil)` → `nil` ("Default" option).
/// `.explicit(v)` → `v`.
/// `.explicit(nil)` has no distinct Picker representation and collapses to `.inherit` on round-trip — intentional.
public func inheritedSHKCToSelection(_ inherited: Inherited<StrictHostKeyChecking>) -> StrictHostKeyChecking? {
    inherited.value
}

/// Converts a `StrictHostKeyChecking?` Picker selection back to
/// `Inherited<StrictHostKeyChecking>`.
/// `nil` → `.inherit`; a case → `.explicit(case)`.
public func selectionToInheritedSHKC(_ selection: StrictHostKeyChecking?) -> Inherited<StrictHostKeyChecking> {
    guard let v = selection else { return .inherit }
    return .explicit(v)
}

// MARK: - Inherited<[AuthMethod]>

/// Converts `Inherited<[AuthMethod]>` to a `Set<AuthMethod>?` for multi-toggle UI.
/// `.inherit` and `.explicit(nil)` → `nil` (no selection; "use default").
/// `.explicit(methods)` → `Set(methods)` (selected methods, order lost on round-trip).
/// `.explicit(nil)` has no distinct Picker representation and collapses to `.inherit` on round-trip — intentional.
public func inheritedAuthMethodsToSelection(_ inherited: Inherited<[AuthMethod]>) -> Set<AuthMethod>? {
    guard let methods = inherited.value else { return nil }
    return Set(methods)
}

/// Converts a `Set<AuthMethod>?` back to `Inherited<[AuthMethod]>`.
/// `nil` → `.inherit`; a set (even empty) → `.explicit([...])` in canonical order.
/// Canonical order: `.publicKey`, `.password`, `.keyboardInteractive`.
public func selectionToInheritedAuthMethods(_ selection: Set<AuthMethod>?) -> Inherited<[AuthMethod]> {
    guard let set = selection else { return .inherit }
    let ordered: [AuthMethod] = [.publicKey, .password, .keyboardInteractive].filter { set.contains($0) }
    return .explicit(ordered)
}
