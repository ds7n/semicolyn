// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The display glyph for a swipe secondary: a literal renders as itself; a key
/// renders as its symbol (tab -> ⇥, shift-tab -> ⇤, escape -> ⎋, enter -> ⏎,
/// backspace -> ⌫, arrows -> ↑↓←→, Fn -> "F<n>", char -> the char). Pure so the
/// keybar's hint labels are unit-tested on Linux, not only visually on device.
public func hintGlyph(for v: SecondaryValue) -> String {
    switch v {
    case .literal(let s): return s
    case .key(let input, let mods):
        switch input {
        case .tab:       return mods.shift ? "⇤" : "⇥"
        case .escape:    return "⎋"
        case .enter:     return "⏎"
        case .backspace: return "⌫"
        case .arrow(let d):
            switch d { case .up: return "↑"; case .down: return "↓"
                       case .left: return "←"; case .right: return "→" }
        case .function(let n): return "F\(n)"
        case .char(let c):     return String(c)
        }
    }
}

/// The up/down hint glyphs for a key, each nil when that direction is unbound.
/// A pure projection of `SwipeSecondaries` onto (up, down) display strings, so the
/// slot view can render the stacked hint column (up over down) without logic.
public func hintGlyphs(for s: SwipeSecondaries) -> (up: String?, down: String?) {
    (up: s.up.map(hintGlyph(for:)), down: s.down.map(hintGlyph(for:)))
}
