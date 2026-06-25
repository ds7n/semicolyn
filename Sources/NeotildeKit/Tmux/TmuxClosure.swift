// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How a `tmux -CC` control-mode channel ended (degraded-mode spec §"Mid-session
/// tmux crash recovery").
public enum TmuxClosureKind: Equatable, Sendable {
    /// A `%exit` was observed first — the user or server ended the session cleanly.
    case cleanExit(reason: String?)
    /// The channel hit EOF with no `%exit` — tmux died (OOM, `kill-server`, segfault).
    case crashed
}

/// Classify a `-CC` channel close from the controller lifecycle at EOF time. Only
/// `.exited` (a parsed `%exit`) is clean; any other state means the stream dropped
/// unexpectedly and we must offer crash recovery.
public func classifyTmuxClosure(lifecycle: TmuxLifecycle) -> TmuxClosureKind {
    if case .exited(let reason) = lifecycle { return .cleanExit(reason: reason) }
    return .crashed
}
