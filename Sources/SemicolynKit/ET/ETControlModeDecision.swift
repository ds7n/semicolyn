// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Outcome of the ET `-CC` control-mode watchdog when it fires. Pure +
/// Linux-tested so both the decision AND the user-facing failure message are
/// covered off the Apple-only App gate, mirroring `ETExitDecision`.
///
/// On the ET `-CC` path the app sends `tmux -CC new-session …` in-band once the ET
/// stream is up (`onFirstFrame`). If the remote has no `tmux` (or a version without
/// control mode), tmux never emits `%begin`, the control-mode session never crosses
/// `.attaching → .attached`, and the native pane container stays empty forever. A
/// short watchdog resolves that dead state: if the handshake was seen it is a no-op
/// (`.ready`), otherwise the app fails with the banner carried here.
public enum ETControlModeDecision: Equatable, Sendable {
    /// The `%begin` handshake landed before the watchdog fired: control mode is up,
    /// the watchdog does nothing.
    case ready
    /// The watchdog fired with no handshake: tmux `-CC` never started. The App tears
    /// the session down and shows the `.failed` banner carrying this message.
    case failedNoControlMode(String)
}

/// Classify the ET `-CC` control-mode watchdog outcome.
/// - Parameter handshakeSeen: whether tmux's `%begin` (the `.attaching → .attached`
///   edge, surfaced as `TmuxRuntime.onControlReady`) was observed before the
///   watchdog fired.
///
/// The failure message is a fixed constant (no untrusted input flows in), so unlike
/// `etExitDecision` there is nothing to sanitize.
public func etControlModeDecision(handshakeSeen: Bool) -> ETControlModeDecision {
    handshakeSeen
        ? .ready
        : .failedNoControlMode(
            "tmux control mode did not start on this host. "
            + "Check that tmux is installed and supports control mode (-CC, tmux 3.0+).")
}
