// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Translates finger drag deltas into whole-cell cursor moves for the cursor-placement
/// gesture (`docs/brainstorming-decisions.md` §"Cursor placement"). Delta-based, mouse-like:
/// each step applies a speed-dependent gain, converts points→fractional cells, enforces a
/// 1.5-cell vertical dead-zone (horizontal-only until crossed, then unlocked for the rest of
/// the gesture), and carries a sub-cell remainder so fractional motion accumulates without
/// drift. Pure + timestamp-injected, mirroring `BellStateMachine`/`ResizeDebounce`; the App
/// measures finger speed and cell metrics and turns the returned counts into arrow keys.
public struct CursorDragEngine: Equatable, Sendable {
    /// At or below this finger speed (pt/s) gain is 1:1 — the precision zone.
    public static let precisionSpeed: Double = 600
    /// Acceleration cap — the long-jump zone never exceeds this multiplier.
    public static let maxGain: Double = 3
    /// Finger-speed span (pt/s) over which gain ramps `precisionSpeed`→`maxGain`.
    public static let accelRange: Double = 1200
    /// Cumulative vertical travel (cells) before vertical motion unlocks (anti-readline-footgun).
    public static let verticalDeadzoneCells: Double = 1.5

    private var verticalUnlocked = false
    private var cumulativeVertical = 0.0 // cells of |vertical| finger travel this gesture
    private var remX = 0.0               // sub-cell horizontal remainder (fractional cells)
    private var remY = 0.0               // sub-cell vertical remainder

    public init() {}

    /// Gain for a finger speed: 1.0 at/below `precisionSpeed`, ramping linearly to `maxGain`
    /// across `accelRange`, clamped at `maxGain`.
    public static func gain(forSpeed speed: Double) -> Double {
        guard speed > precisionSpeed else { return 1 }
        let t = (speed - precisionSpeed) / accelRange
        return min(maxGain, 1 + t * (maxGain - 1))
    }

    /// Reset state for a new gesture (touch engage).
    public mutating func begin() {
        verticalUnlocked = false
        cumulativeVertical = 0
        remX = 0
        remY = 0
    }

    /// Consume a finger delta (points since the last step; +dy = downward) and return the
    /// whole signed cell counts to emit: +cols = Right, −cols = Left, +rows = Down, −rows = Up.
    /// `speed` is the instantaneous finger speed (pt/s, App-measured); `now` is injected for
    /// parity with the other engines (unused in v1).
    public mutating func step(fingerDelta: (dx: Double, dy: Double), speed: Double,
                              cellW: Double, cellH: Double, at now: Date) -> (cols: Int, rows: Int) {
        guard cellW > 0, cellH > 0 else { return (0, 0) }
        let g = Self.gain(forSpeed: speed)
        let cellsX = fingerDelta.dx * g / cellW
        var cellsY = fingerDelta.dy * g / cellH

        // Vertical dead-zone: track intended |vertical| travel; clamp to horizontal-only until
        // it crosses the threshold, then stay unlocked for the rest of the gesture.
        cumulativeVertical += abs(cellsY)
        if !verticalUnlocked {
            if cumulativeVertical >= Self.verticalDeadzoneCells {
                verticalUnlocked = true
            } else {
                cellsY = 0
            }
        }

        // Sub-cell remainder carry: emit whole cells now, keep the fraction for next step.
        remX += cellsX
        remY += cellsY
        let cols = Int(remX.rounded(.towardZero))
        let rows = Int(remY.rounded(.towardZero))
        remX -= Double(cols)
        remY -= Double(rows)
        return (cols, rows)
    }

    /// End the gesture (touch lift); clears state.
    public mutating func end() {
        verticalUnlocked = false
        cumulativeVertical = 0
        remX = 0
        remY = 0
    }
}
