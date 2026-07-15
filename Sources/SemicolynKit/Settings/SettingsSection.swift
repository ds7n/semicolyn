// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Where the unified Settings screen is being shown from.
public enum SettingsContext: Equatable, Sendable {
    case preConnect   // host list, no active session
    case inSession    // long-press Esc, active session
}

/// The sections of the unified Settings screen.
public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance, terminal, keybar, launcher, defaults, privacy, diagnostics, experimental
}

/// Decides which Settings sections are interactive in a given context. Keybar and
/// Launcher edit the LIVE session's input surface, so they are disabled pre-connect;
/// every other section applies in both contexts.
public enum SettingsGate {
    public static func isEnabled(_ section: SettingsSection, in context: SettingsContext) -> Bool {
        switch section {
        case .keybar, .launcher: return context == .inSession
        default:                 return true
        }
    }
}
