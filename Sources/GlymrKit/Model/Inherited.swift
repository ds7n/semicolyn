// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Distinguishes three states the schema requires from day one:
/// `.inherit` (field absent → inherit from Defaults, then built-in),
/// `.explicit(value)` (set), and `.explicit(nil)` (explicitly cleared to "none").
/// Baked in now so per-group/pattern defaults never need a migration.
public enum Inherited<T: Equatable & Codable>: Equatable, Codable {
    case inherit
    case explicit(T?)

    /// The set value if explicitly set to a non-nil value, else nil.
    public var value: T? {
        if case let .explicit(v) = self { return v }
        return nil
    }
}

// Conditionally `Sendable` so `Host`/`Defaults` (which are `Sendable`) can hold
// `Inherited<T>` fields under Swift 6 strict concurrency. Every T used here
// (String, Int, [UUID], [JumpHop]) is itself Sendable.
extension Inherited: Sendable where T: Sendable {}
