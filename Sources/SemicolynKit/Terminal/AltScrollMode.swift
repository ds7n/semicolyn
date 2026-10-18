// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an alt-screen scroll gesture synthesizes input. Two mutually-exclusive modes.
/// The raw values are persisted in `TerminalSettings`, so they must not change.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case wheel           // synthesize SGR mouse-wheel events for every alt-screen app [DEFAULT]
    case pageKeysArrows  // FALLBACK: arrow keys (the name predates dropping the PgUp/PgDn branch)
}

/// The input family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, wheel }

/// A resolved alt-screen scroll decision: the chosen key family PLUS the input and the
/// branch reason that produced it. Returned by `altScrollDecision(mode:)` so the App can log a
/// self-contained line (`decision.logLine`) reflecting exactly what the pure decider saw:
/// the reason is derived from the branch taken, so it can never disagree with `keys`.
public struct AltScrollDecision: Sendable, Equatable {
    public let keys: AltScrollKeys
    public let mode: AltScrollMode
    public let reason: String

    /// Explicit public memberwise init: a `public struct`'s synthesized init is `internal`.
    public init(keys: AltScrollKeys, mode: AltScrollMode, reason: String) {
        self.keys = keys
        self.mode = mode
        self.reason = reason
    }

    /// Self-contained one-liner. Format: `mode=X → keys=Z reason=R`.
    public var logLine: String {
        "mode=\(mode.rawValue) → keys=\(keys) reason=\(reason)"
    }
}

/// The pure alt-scroll decision the App snapshots once at drag `.began`. `.wheel` (default) is
/// app-agnostic: every alt-screen app scrolls via synthetic mouse-wheel events (the Blink model,
/// ~1 line each). `.pageKeysArrows` is the fallback for apps that ignore wheel events: arrows.
public func altScrollDecision(mode: AltScrollMode) -> AltScrollDecision {
    switch mode {
    case .wheel:          return AltScrollDecision(keys: .wheel, mode: mode, reason: "wheel")
    case .pageKeysArrows: return AltScrollDecision(keys: .arrows, mode: mode, reason: "fallback")
    }
}
