// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure geometry for the window-switch gap dimming. As the CURRENT window slides off,
/// the exposed gap behind it darkens with drag progress; the gradient is darkest at the
/// edge nearest the departing window and fades across the gap. This unit owns the opacity
/// ramp and the gradient x-endpoints (direction); the App layer applies them to a
/// `CAGradientLayer` / overlay `UIView`.
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

    /// Gradient x-endpoints in unit coordinates (0 = left edge, 1 = right edge; y is fixed
    /// at 0.5 by the App layer). `startX` is the DARK end (nearest the departing window),
    /// `endX` the clear end.
    public struct Endpoints: Equatable, Sendable {
        public let startX: Double
        public let endX: Double
        public init(startX: Double, endX: Double) { self.startX = startX; self.endX = endX }
    }

    /// Endpoints for the drag direction. `.previous` (rightward drag): the window slides
    /// RIGHT, the gap opens on the LEFT, and the departing window is to the gap's RIGHT ->
    /// dark on the right (startX = 1), fading left (endX = 0). `.next` mirrors it. `.none`
    /// -> a zero-span default (no direction implied).
    public static func endpoints(exposed: ExposedNeighbor) -> Endpoints {
        switch exposed {
        case .previous: return Endpoints(startX: 1.0, endX: 0.0)
        case .next:     return Endpoints(startX: 0.0, endX: 1.0)
        case .none:     return Endpoints(startX: 0.5, endX: 0.5)
        }
    }
}
