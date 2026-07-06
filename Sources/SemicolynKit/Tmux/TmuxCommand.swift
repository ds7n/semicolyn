// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Direction of a `split-window`, named by the resulting divider to sidestep the
/// classic "split vertically" ambiguity (see the command-encoder design spec).
public enum SplitDirection: Sendable {
    /// New pane to the right, a vertical divider between them → tmux `-h`.
    case sideBySide
    /// New pane below, a horizontal divider between them → tmux `-v`.
    case stacked

    fileprivate var flag: String {
        switch self {
        case .sideBySide: return "-h"
        case .stacked: return "-v"
        }
    }
}

/// Pure encoder for outbound `tmux -CC` control-mode command lines — the inverse
/// of ``ControlModeParser``. Each function returns one command line **without** a
/// trailing newline (the transport appends exactly one `\n`); output is
/// guaranteed free of `\n`/`\r` so newline framing can never be forged from an
/// argument. Invalid input fails closed (`nil`) rather than emitting an unsafe or
/// malformed command. Stateless: owns no I/O and no session state — the `-CC`
/// handshake and command sequencing are a separate controller slice.
public enum TmuxCommand {
    /// Open a new window in the attached session.
    public static func newWindow() -> String {
        "new-window"
    }

    /// Split `target` into a second pane. ``SplitDirection`` picks the tmux flag.
    public static func splitWindow(target: PaneID, direction: SplitDirection) -> String {
        "split-window \(direction.flag) -t \(target.targetToken)"
    }

    /// Resize `target` to `width`×`height` cells. Returns nil unless both are ≥ 1.
    public static func resizePane(target: PaneID, width: Int, height: Int) -> String? {
        guard width >= 1, height >= 1 else { return nil }
        return "resize-pane -t \(target.targetToken) -x \(width) -y \(height)"
    }

    /// Toggle zoom (fullscreen) on `target`.
    public static func zoomPane(target: PaneID) -> String {
        "resize-pane -Z -t \(target.targetToken)"
    }

    /// Make `target` the active window.
    public static func selectWindow(target: WindowID) -> String {
        "select-window -t \(target.targetToken)"
    }

    /// Make `target` the active pane.
    public static func selectPane(target: PaneID) -> String {
        "select-pane -t \(target.targetToken)"
    }

    /// Move to the next (`+`) or previous (`-`) pane in the active window — the
    /// relative target tmux resolves without us tracking pane ids (Phase 4e
    /// `⌘[` / `⌘]`).
    public static func selectPaneRelative(next: Bool) -> String {
        "select-pane -t \(next ? "+" : "-")"
    }

    /// Kill `target`.
    public static func killPane(target: PaneID) -> String {
        "kill-pane -t \(target.targetToken)"
    }

    /// Kill `target` window (Phase 4e `⌘W`).
    public static func killWindow(target: WindowID) -> String {
        "kill-window -t \(target.targetToken)"
    }

    /// Send `bytes` as terminal input to `target`, hex-encoded via `send-keys -H`
    /// so arbitrary bytes (control chars, UTF-8, the framing `\n`/`\r`) round-trip
    /// exactly and can never escape their argument position. Returns nil for an
    /// empty payload (a no-op send is a caller bug).
    public static func sendKeys(target: PaneID, bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "send-keys -t \(target.targetToken) -H \(hex)"
    }

    /// Tell tmux the control-client's size in cells so it re-tiles all windows.
    /// tmux responds with `%layout-change`. Returns nil unless both are ≥ 1.
    public static func refreshClientSize(width: Int, height: Int) -> String? {
        guard width >= 1, height >= 1 else { return nil }
        return "refresh-client -C \(width)x\(height)"
    }

    /// List every pane across all windows as `<pane_id> <pane_current_command>`,
    /// one per line, for context detection. The format string is a constant (no
    /// interpolated input) and contains no `\n`/`\r`, so framing is never forgeable.
    public static func listPaneCommands() -> String {
        "list-panes -a -F \"#{pane_id} #{pane_current_command}\""
    }

    /// `list-windows` formatted for attach-time layout discovery: each row is
    /// `<window_id> <window_active> <window_layout>` (e.g. `@0 1 abcd,80x24,0,0,0`).
    /// Parsed by ``parseWindowListing(_:)`` when `-CC` attaches to a session that
    /// emitted no spontaneous `%window-add`/`%layout-change`.
    public static func listWindowsForLayout() -> String {
        "list-windows -F \"#{window_id} #{window_active} #{window_layout}\""
    }

    /// Kill the session named `name`. Validates against the session-name charset
    /// `[A-Za-z0-9_-]` (`isValidTmuxSessionName`) and returns nil for anything else.
    /// Names are user-choosable (the configurable-session-name feature), so an
    /// invalid name is a real possibility, not a bug — rejecting it keeps the name
    /// safe to interpolate without shell-quoting.
    public static func killSession(name: String) -> String? {
        guard isValidTmuxSessionName(name) else { return nil }
        return "kill-session -t \(name)"
    }
}

extension PaneID {
    /// `%N` target form for a tmux command argument.
    fileprivate var targetToken: String { "%\(raw)" }
}
extension WindowID {
    /// `@N` target form for a tmux command argument.
    fileprivate var targetToken: String { "@\(raw)" }
}
