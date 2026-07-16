// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an alt-screen scroll gesture chooses which keys to synthesize. A single
/// user-facing setting (radio); modes are mutually exclusive by construction.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case off             // always arrows (xterm standard)
    case auto            // arrows, except a registered app in a tmux pane -> page keys [DEFAULT]
    case alwaysPageKeys  // every alt-screen drag -> page keys (breaks less/vim line-scroll)
    case autoPlusTitle   // auto, plus best-effort OSC-title match on non-tmux (brittle)
}

/// The key family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys }

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

/// The pure alt-scroll decision the App snapshots once at drag `.began`.
/// - windowTitle: OSC 0/2 title; consulted only in `.autoPlusTitle` when `paneCommand` is nil.
public func altScrollDecision(mode: AltScrollMode,
                              paneCommand: String?,
                              windowTitle: String?,
                              registry: AltScrollRegistry) -> AltScrollDecision {
    let (keys, reason): (AltScrollKeys, String)
    switch mode {
    case .off:
        (keys, reason) = (.arrows, "off")
    case .auto:
        let page = registry.wantsPageKeys(command: paneCommand)
        (keys, reason) = (page ? .pageKeys : .arrows,
                          page ? "auto:registered" : "auto:unregistered")
    case .alwaysPageKeys:
        (keys, reason) = (.pageKeys, "alwaysPageKeys")
    case .autoPlusTitle:
        if let cmd = paneCommand {
            (keys, reason) = (registry.wantsPageKeys(command: cmd) ? .pageKeys : .arrows,
                              "autoPlusTitle:cmd")
        } else {
            (keys, reason) = (registry.wantsPageKeys(title: windowTitle) ? .pageKeys : .arrows,
                              "autoPlusTitle:title")
        }
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
