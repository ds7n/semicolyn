// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The rows of the unified Settings screen. Every row is enabled in every context:
/// Keybar and Macros edit the same global store before connecting and in a session,
/// so changes made from the host list apply to the next session.
public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance, terminal, keybar, macros, keyboard, defaults, privacy, tips, diagnostics

    /// The row title (also the pushed screen's title).
    public var title: String {
        switch self {
        case .appearance:  return "Appearance"
        case .terminal:    return "Terminal"
        case .keybar:      return "Keybar"
        case .macros:      return "Macros"
        case .keyboard:    return "Keyboard"
        case .defaults:    return "Connection Defaults"
        case .privacy:     return "Suggestions & Privacy"
        case .tips:        return "Tips & Gestures"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// The SF Symbol shown beside the title.
    public var symbol: String {
        switch self {
        case .appearance:  return "paintpalette"
        case .terminal:    return "terminal"
        case .keybar:      return "keyboard"
        case .macros:      return "command"
        case .keyboard:    return "keyboard.badge.ellipsis"
        case .defaults:    return "slider.horizontal.3"
        case .privacy:     return "hand.raised"
        case .tips:        return "questionmark.circle"
        case .diagnostics: return "ladybug"
        }
    }
}

/// One headed group of Settings rows. `header == nil` is the un-headed first group.
public struct SettingsGroup: Equatable, Sendable {
    public let header: String?
    public let sections: [SettingsSection]
    public init(header: String?, sections: [SettingsSection]) {
        self.header = header
        self.sections = sections
    }
}

/// The Settings screen layout, top to bottom (below the in-session Session section).
/// Each `SettingsSection` appears exactly once.
public enum SettingsLayout {
    public static let groups: [SettingsGroup] = [
        SettingsGroup(header: nil, sections: [.appearance, .terminal]),
        SettingsGroup(header: "Input", sections: [.keybar, .macros, .keyboard]),
        SettingsGroup(header: "Connections", sections: [.defaults]),
        SettingsGroup(header: "Privacy", sections: [.privacy]),
        SettingsGroup(header: "Help", sections: [.tips, .diagnostics]),
    ]
}
