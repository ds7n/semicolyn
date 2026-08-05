// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The connection transport for a host: chosen explicitly by the user (no Auto).
/// SSH is the universally-available default; Mosh roams but has no panes; ET has
/// panes and roaming but needs etserver on the host.
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
            return "Works everywhere, native tmux panes, does not survive roaming."
        case .mosh:
            return "Survives roaming, no native panes, needs mosh-server + a UDP port range."
        case .et:
            return "Panes and roaming, needs etserver on the host + TCP 2022, failure is shown (no silent switch)."
        }
    }
}
