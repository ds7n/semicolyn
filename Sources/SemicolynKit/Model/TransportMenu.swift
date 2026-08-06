// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether the "Attempt tmux control mode" toggle should be shown for a given transport.
///
/// tmux `-CC` (control mode) runs over any interactive PTY stream, so it is transport
/// agnostic in principle: SSH and ET can both host it. Mosh structurally cannot run
/// tmux `-CC` (documented incompatibility), so the toggle is hidden for Mosh. Note: ET
/// does not yet WIRE tmux `-CC` (that is a later slice); the toggle is shown for ET with
/// a "wiring pending" subtitle so the menu is correct in principle and ready for it.
public func showsTmuxControlToggle(transport: Transport) -> Bool {
    switch transport {
    case .ssh, .et: return true
    case .mosh: return false
    }
}
