// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#if canImport(SwiftUI)
import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .bellBronze
}

extension EnvironmentValues {
    /// The active theme; changing it propagates through the view tree.
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    /// Builds a SwiftUI `Color` from a `ThemeColor` (hex + opacity), reusing the
    /// agnostic `rgba()` parser so the math is identical to what's unit-tested.
    public init(_ themeColor: ThemeColor) {
        let c = themeColor.rgba()
        self = Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.opacity)
    }
}
#endif
