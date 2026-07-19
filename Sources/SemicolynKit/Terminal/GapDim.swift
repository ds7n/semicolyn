// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure opacity ramp for the window-switch card dimming. As the current window (card)
/// drags off, the whole card darkens UNIFORMLY with drag progress (device 2026-07-19:
/// replaced a side-gradient that dimmed the wrong edge; the dim now rides the card itself).
/// This unit owns just the opacity ramp; the App layer applies it to a `UIView.alpha`.
public struct GapDim: Sendable {
    /// Peak dim (fraction) reached at a full-width drag. 0.5 = a clear but not opaque grey.
    public static let maxOpacity: Double = 0.5

    /// Overlay opacity for a drag of `offset` over a pane of `width`: linear ramp from 0
    /// (at rest) to `maxOpacity` (at a full-width drag), clamped past width. Sign-agnostic
    /// (uses `abs`). `width <= 0` -> 0 (no dim, no divide-by-zero).
    public static func opacity(offset: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(abs(offset) / width, 1) * maxOpacity
    }
}
