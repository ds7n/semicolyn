// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which adjacent window the exposed gap reveals during a live horizontal drag.
public enum ExposedNeighbor: Equatable, Sendable {
    case none
    case previous   // rightward drag (dx > 0): content-follows-finger reveals the window to the left
    case next       // leftward drag (dx < 0)
}

/// Pure geometry for the live finger-drag window transition. Maps the pan's horizontal
/// translation to the content view's visual offset (identity at rest, clamped/rubber-
/// banded past a full window width so an over-drag past the edge windows resists instead
/// of running off), and reports which neighbor the resulting gap exposes.
public struct WindowDragModel: Sendable {
    /// Resistance applied to over-drag past +/- one window width (0 = free, 1 = locked).
    /// 0.5 gives the standard iOS rubber-band feel.
    private static let rubberBandResistance: Double = 0.5

    /// Content translation (points) for a drag of `dx` over a pane of `width`. Within
    /// +/-width it is `dx` unchanged; past the edge it moves at reduced rate so an
    /// over-drag past the first/last-revealed window resists (rubber-band) and never
    /// exceeds ~2*width.
    public static func offset(dx: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        if abs(dx) <= width { return dx }
        let over = abs(dx) - width
        let resisted = width + over * rubberBandResistance
        return dx > 0 ? resisted : -resisted
    }

    /// The neighbor the exposed gap reveals, by drag-direction sign (content-follows-
    /// finger). No horizontal movement reveals nothing.
    public static func exposedNeighbor(dx: Double) -> ExposedNeighbor {
        if dx > 0 { return .previous }
        if dx < 0 { return .next }
        return .none
    }
}
