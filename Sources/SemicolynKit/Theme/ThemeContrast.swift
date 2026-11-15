// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// WCAG 2.x contrast math for theme colors. Pure, so the palette contrast floors
// (light-theme-variants spec) are unit-tested on Linux.

extension ThemeColor {
    /// WCAG relative luminance of the color's RGB (opacity ignored), 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        let c = rgba()
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// This color at its opacity drawn over an opaque `bg`, mixed in sRGB space and
    /// rounded to whole 0-255 channels, returned opaque.
    public func composited(over bg: ThemeColor) -> ThemeColor {
        let f = rgba(), b = bg.rgba()
        let a = f.opacity
        func hex2(_ fv: Double, _ bv: Double) -> String {
            let v = Int(((fv * a + bv * (1 - a)) * 255).rounded())
            return String(format: "%02X", min(255, max(0, v)))
        }
        return ThemeColor("#" + hex2(f.red, b.red) + hex2(f.green, b.green) + hex2(f.blue, b.blue))
    }
}

/// WCAG contrast ratio (1 to 21) of `foreground` on `background`. A translucent
/// foreground is composited over the background first; the background is treated as
/// opaque.
public func contrastRatio(_ foreground: ThemeColor, _ background: ThemeColor) -> Double {
    let fg = foreground.opacity < 1 ? foreground.composited(over: background) : foreground
    let l1 = fg.relativeLuminance, l2 = background.relativeLuminance
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}
