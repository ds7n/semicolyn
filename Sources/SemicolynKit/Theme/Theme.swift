// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A resolved color reference: a palette hex plus an opacity multiplier.
/// Tokens hold `ThemeColor` values so equality is testable without rendering.
/// This type is platform-agnostic — no SwiftUI here (see ThemeEnvironment.swift).
public struct ThemeColor: Equatable, Sendable {
    public let hex: String
    public let opacity: Double

    public init(_ hex: String, opacity: Double = 1.0) {
        self.hex = hex
        self.opacity = opacity
    }

    /// Returns a copy of this color at the given opacity (0...1).
    public func alpha(_ opacity: Double) -> ThemeColor {
        ThemeColor(hex, opacity: opacity)
    }

    /// Parses the `#RRGGBB` hex into normalized components plus the opacity.
    /// Pure math — unit-tested on Linux; the SwiftUI `Color` bridge consumes it.
    public func rgba() -> (red: Double, green: Double, blue: Double, opacity: Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(s, radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255,
                Double(v & 0xFF) / 255,
                opacity)
    }
}

/// The full semantic-token set for one theme. UI references these tokens only —
/// never palette constants or raw hex. Adding tokens is additive; never inline.
public struct Theme: Equatable, Sendable {
    public struct Surface: Equatable, Sendable {
        public let bg, panel, panelHigh, line: ThemeColor
    }
    public struct Text: Equatable, Sendable {
        public let primary, secondary, muted, inverse: ThemeColor
    }
    public struct Accent: Equatable, Sendable {
        public let primary, highlight: ThemeColor
    }
    public struct State: Equatable, Sendable {
        public let success, degraded, broken, warning: ThemeColor
    }
    public struct Bell: Equatable, Sendable {
        public let edge: ThemeColor
    }
    public struct Focus: Equatable, Sendable {
        public let paneBorder, paneBorderInactive: ThemeColor
    }
    public struct Keybar: Equatable, Sendable {
        public let slotBg, slotBgPromoted, slotBgArmed, slotBgLocked: ThemeColor
    }
    public struct Predictor: Equatable, Sendable {
        public let stripBg, suggestionBg, suggestionText: ThemeColor
    }
    public struct Banner: Equatable, Sendable {
        public let amberBg, redBg, neutralBg: ThemeColor
    }
    public struct Terminal: Equatable, Sendable {
        public let bg, fg, cursor, cursorText, selection: ThemeColor
        /// New fields default so existing `.init(bg:fg:)` call sites keep compiling:
        /// cursor→fg, cursorText→bg, selection→fg @ 30%.
        public init(bg: ThemeColor, fg: ThemeColor,
                    cursor: ThemeColor? = nil, cursorText: ThemeColor? = nil,
                    selection: ThemeColor? = nil) {
            self.bg = bg
            self.fg = fg
            self.cursor = cursor ?? fg
            self.cursorText = cursorText ?? bg
            self.selection = selection ?? fg.alpha(0.30)
        }
    }

    public let surface: Surface
    public let text: Text
    public let accent: Accent
    public let state: State
    public let bell: Bell
    public let focus: Focus
    public let keybar: Keybar
    public let predictor: Predictor
    public let banner: Banner
    public let terminal: Terminal
    /// Authored 16-color ANSI palette — source of hue for the terminal + UI refs.
    public let ansi: ANSIPalette

    public init(surface: Surface, text: Text, accent: Accent, state: State,
                bell: Bell, focus: Focus, keybar: Keybar, predictor: Predictor,
                banner: Banner, terminal: Terminal,
                ansi: ANSIPalette = ANSIPalette.neutralFallback) {
        self.surface = surface; self.text = text; self.accent = accent
        self.state = state; self.bell = bell; self.focus = focus
        self.keybar = keybar; self.predictor = predictor; self.banner = banner
        self.terminal = terminal; self.ansi = ansi
    }
}
