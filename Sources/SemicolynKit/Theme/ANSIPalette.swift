// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The 16 ANSI colors in SwiftTerm's `installColors` index order — `rawValue`
/// IS the palette index (0…15), so the enum doubles as the ordering key.
public enum ANSISlot: Int, CaseIterable, Sendable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite
}

/// A theme's authored 16-color ANSI palette — the single source of hue.
/// UI semantic tokens reference into this; the terminal bridge installs `ordered()`.
public struct ANSIPalette: Equatable, Sendable {
    private let colors: [ThemeColor]

    /// - Parameter colors: exactly 16 colors, indexed by `ANSISlot.rawValue`.
    public init(_ colors: [ThemeColor]) {
        precondition(colors.count == 16, "ANSIPalette requires exactly 16 colors")
        self.colors = colors
    }

    /// Resolves a role's slot to its authored color.
    public subscript(_ slot: ANSISlot) -> ThemeColor { colors[slot.rawValue] }

    /// The 16 colors in index order, ready for `installColors`.
    public func ordered() -> [ThemeColor] { colors }
}

extension ANSIPalette {
    /// A neutral placeholder used only until a theme is migrated to `fromANSI`.
    /// Standard xterm-ish 16; real themes author their own.
    public static let neutralFallback = ANSIPalette([
        "#000000", "#CD0000", "#00CD00", "#CDCD00", "#0000EE", "#CD00CD", "#00CDCD", "#E5E5E5",
        "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00", "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF",
    ].map { ThemeColor($0) })
}
