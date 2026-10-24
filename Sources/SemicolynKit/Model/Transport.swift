// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The connection transport for a host ("Connection type" in the editors): chosen
/// explicitly by the user (no Auto). SSH is the universally-available default; Mosh
/// and ET stay connected across network changes but need their server installed.
/// Gesture-driven tmux works on all three.
public enum Transport: String, Codable, Sendable, CaseIterable, Equatable {
    case ssh, mosh, et

    /// Short label for the picker.
    public var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .et: return "Eternal Terminal"
        }
    }

    /// One-line tradeoff guidance shown under the picker.
    public var summary: String {
        switch self {
        case .ssh:
            return "Works with any server. Drops when your network changes."
        case .mosh:
            return "Stays connected when your network changes or the phone sleeps. Needs mosh-server and open UDP ports."
        case .et:
            return "Stays connected when your network changes. Needs etserver on the server (TCP 2022)."
        }
    }
}
