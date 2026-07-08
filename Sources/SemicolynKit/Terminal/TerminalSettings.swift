// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Caret rendering style, independent of blink (mirrors DECSCUSR families).
public enum CursorStyle: Equatable, Sendable { case block, underline, bar }

/// A selectable terminal typeface. `.system` = SF Mono (no icons); `.bundled`
/// = a Nerd Font shipped in the app bundle; `.imported` = a user-registered
/// `.ttf`/`.otf`. The associated `String` is the font's PostScript name.
public struct TerminalFont: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case system
        case bundled(String)
        case imported(String)
    }
    public var kind: Kind
    public var displayName: String
    public init(kind: Kind, displayName: String) {
        self.kind = kind
        self.displayName = displayName
    }
}

/// A font shipped inside the app bundle. `fileName` is the resource file
/// (without extension assumptions handled by the App tier); `postScriptName`
/// is what `UIFont(name:)` needs; `license` is the SPDX / upstream id.
public struct BundledFont: Equatable, Sendable {
    public let displayName: String
    public let postScriptName: String
    public let fileName: String
    public let license: String
    public var face: TerminalFont {
        TerminalFont(kind: .bundled(postScriptName), displayName: displayName)
    }
}

/// The curated font set + the resolve-with-fallback that keeps an unresolvable
/// face from tofu-ing the whole terminal.
public enum FontCatalog {
    public static let bundled: [BundledFont] = [
        BundledFont(displayName: "Hack Nerd Font",
                    postScriptName: "HackNerdFont-Regular",
                    fileName: "HackNerdFont-Regular",
                    license: "MIT"),
        BundledFont(displayName: "JetBrainsMono Nerd Font",
                    postScriptName: "JetBrainsMonoNerdFont-Regular",
                    fileName: "JetBrainsMonoNerdFont-Regular",
                    license: "OFL-1.1"),
    ]
    public static let `default`: BundledFont = bundled[0]   // Hack — mobile-legible

    /// Resolve a face to the PostScript name to render with.
    /// - Returns: `nil` for `.system` (caller uses `monospacedSystemFont`);
    ///   the exact name for bundled or a registered imported face; the default
    ///   bundled font's name for an imported face not in `registeredImported`.
    public static func resolvePostScriptName(
        _ face: TerminalFont, registeredImported: Set<String>) -> String? {
        switch face.kind {
        case .system:
            return nil
        case .bundled(let name):
            return name
        case .imported(let name):
            return registeredImported.contains(name) ? name : `default`.postScriptName
        }
    }
}

/// Terminal rendering preferences. Pure value type; defaults baked in per the
/// Plan C spec. A future Settings screen binds to this; Plan C ships defaults.
public struct TerminalSettings: Equatable, Sendable {
    public var fontSize: Double
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    public var scrollbackLines: Int
    public var fontFace: TerminalFont

    /// Allowed font-point range (touch-legible floor, sane ceiling).
    public static let fontRange: ClosedRange<Double> = 9...24
    /// Raw-PTY scrollback presets; `Int.max` represents "unlimited".
    public static let scrollbackPresets: [Int] = [1000, 2000, 5000, 10000, Int.max]

    public init(fontSize: Double = 13,
                cursorStyle: CursorStyle = .block,
                cursorBlink: Bool = false,
                scrollbackLines: Int = 5000,
                fontFace: TerminalFont = FontCatalog.default.face) {
        self.fontSize = TerminalSettings.clampFont(fontSize)
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLines = scrollbackLines
        self.fontFace = fontFace
    }

    /// Clamp a requested font size into the legible range.
    public static func clampFont(_ pt: Double) -> Double {
        min(max(pt, fontRange.lowerBound), fontRange.upperBound)
    }

    /// Map a DECSCUSR parameter (`ESC [ <n> q`) to caret style + blink.
    public static func cursorStyle(fromDECSCUSR n: Int) -> (style: CursorStyle, blink: Bool) {
        switch n {
        case 0, 1: return (.block, true)
        case 2:    return (.block, false)
        case 3:    return (.underline, true)
        case 4:    return (.underline, false)
        case 5:    return (.bar, true)
        case 6:    return (.bar, false)
        default:   return (.block, false)
        }
    }
}
