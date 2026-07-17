// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an alt-screen scroll gesture synthesizes input. Two mutually-exclusive modes.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case wheel           // synthesize SGR mouse-wheel events for every alt-screen app [DEFAULT]
    case pageKeysArrows  // FALLBACK: arrows (less/vim) vs PgUp/PgDn (registered AI-CLIs)
}

/// The input family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys, wheel }

/// A resolved alt-screen scroll decision: the chosen key family PLUS the inputs and the
/// branch reason that produced it. Returned by `altScrollDecision(...)` so the App can log a
/// self-contained line (`decision.logLine`) reflecting exactly what the pure decider saw:
/// the reason is derived from the branch taken, so it can never disagree with `keys`.
/// - paneCommand: tmux `pane_current_command` for this pane; nil on raw/mosh.
public struct AltScrollDecision: Sendable, Equatable {
    public let keys: AltScrollKeys
    public let mode: AltScrollMode
    public let paneCommand: String?
    public let reason: String

    /// Explicit public memberwise init: a `public struct`'s synthesized init is `internal`,
    /// so the App tier (which constructs a default `AltScrollDecision` as the drag snapshot's
    /// initial value) cannot reach the synthesized one across the module boundary.
    public init(keys: AltScrollKeys, mode: AltScrollMode, paneCommand: String?, reason: String) {
        self.keys = keys
        self.mode = mode
        self.paneCommand = paneCommand
        self.reason = reason
    }

    /// Self-contained one-liner (no pane id: the App prepends `pane=%N`, since the pure
    /// decider does not know the pane id). Format: `mode=X app=Y → keys=Z reason=R`.
    public var logLine: String {
        "mode=\(mode.rawValue) app=\(paneCommand ?? "nil") → keys=\(keys) reason=\(reason)"
    }
}

/// The pure alt-scroll decision the App snapshots once at drag `.began`. `.wheel` (default) is
/// app-agnostic: every alt-screen app scrolls via synthetic mouse-wheel events (the Blink model,
/// ~1 line each). `.pageKeysArrows` is the fallback for setups where wheel bytes do not reach the
/// app under tmux -CC: registered AI-CLIs -> PgUp/PgDn, everything else -> arrows.
/// - windowTitle: retained for signature stability; not consulted in either current mode.
public func altScrollDecision(mode: AltScrollMode,
                              paneCommand: String?,
                              windowTitle: String?,
                              registry: AltScrollRegistry) -> AltScrollDecision {
    let (keys, reason): (AltScrollKeys, String)
    switch mode {
    case .wheel:
        (keys, reason) = (.wheel, "wheel")
    case .pageKeysArrows:
        let page = registry.wantsPageKeys(command: paneCommand)
        (keys, reason) = (page ? .pageKeys : .arrows,
                          page ? "fallback:registered" : "fallback:unregistered")
    }
    return AltScrollDecision(keys: keys, mode: mode, paneCommand: paneCommand, reason: reason)
}

/// Behavior-preserving wrapper: existing callers and tests keep the `-> AltScrollKeys`
/// signature. Delegates to `altScrollDecision(...)` so the two can never drift.
public func altScrollKeys(mode: AltScrollMode,
                          paneCommand: String?,
                          windowTitle: String?,
                          registry: AltScrollRegistry) -> AltScrollKeys {
    altScrollDecision(mode: mode, paneCommand: paneCommand,
                      windowTitle: windowTitle, registry: registry).keys
}
