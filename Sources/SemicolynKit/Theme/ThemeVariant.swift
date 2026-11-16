// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The user's Appearance setting: follow the phone, or force light or dark.
/// Case order is the Settings picker order.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    /// The default for a fresh install: follow the phone.
    public static let defaultMode: AppearanceMode = .system

    /// The label shown in the Settings picker.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Which half of a theme family is rendered.
public enum ThemeVariant: Sendable, Equatable {
    case light, dark
}

/// The variant to render: a forced mode wins, otherwise the phone's appearance.
public func resolveVariant(mode: AppearanceMode, systemIsDark: Bool) -> ThemeVariant {
    switch mode {
    case .light: return .light
    case .dark: return .dark
    case .system: return systemIsDark ? .dark : .light
    }
}
