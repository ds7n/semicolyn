// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Pure decider that turns an in-progress alt-screen vertical drag into arrow-key
/// runs to send to the foreground app (xterm "Alternate Scroll" model). The App
/// calls `arrows(...)` on each pan `.changed`, threading the running `emittedCells`
/// so successive samples send only the NEW delta (never double-counting), and the
/// per-emit clamp bounds a fast flick so it can't flood the remote.
///
/// Convention: finger DOWN (+Δy) reveals content above = sends UP arrows (scroll back);
/// finger UP (−Δy) = DOWN arrows. Natural-scroll touch semantics.
public struct AltScreenScroll: Sendable {
    /// Max cells (= arrow presses) turned into arrows in a single `.changed` call.
    /// Bounds a fast flick; feel-tuned. Progress caps at this too, so the running
    /// total advances by at most this per emit.
    public static let maxCellsPerEmit: Int = 24

    /// Scroll gain: how many arrow presses one cell-height of finger travel produces.
    /// A 1.0 mapping (drag one line-height to scroll exactly one line) felt heavy and
    /// sludgy on device (2026-07-16) because content moved no faster than the finger.
    /// >1 makes content outpace the finger, closer to native touch-scroll / mouse-wheel
    /// feel. Feel-tuned; adjust here to taste. The `maxCellsPerEmit` cap still bounds a
    /// fast flick, so gain cannot flood the remote. 2.5 was too fast on device
    /// (2026-07-16 retest, build 53), backed off to 1.8.
    public static let scrollGain: Double = 1.8

    /// Signed cell delta since last emit, clamped to `maxCellsPerEmit`. Shared by `arrows`
    /// (gain = scrollGain) and `wheelEvents` (gain = 1.0). Returns nil when there is nothing to
    /// emit (non-positive cellHeight, or no new whole-cell movement since `emittedCells`).
    private static func signedCellDelta(totalDy: Double, cellHeight: Double,
                                        emittedCells: Int, gain: Double) -> (delta: Int, newEmitted: Int)? {
        guard cellHeight > 0 else { return nil }
        let target = Int(totalDy * gain / cellHeight)
        var delta = target - emittedCells
        if delta == 0 { return nil }
        if delta > maxCellsPerEmit { delta = maxCellsPerEmit }
        if delta < -maxCellsPerEmit { delta = -maxCellsPerEmit }
        return (delta, emittedCells + delta)
    }

    public static func arrows(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard let (delta, newEmitted) = signedCellDelta(totalDy: totalDy, cellHeight: cellHeight,
                                                        emittedCells: emittedCells, gain: scrollGain)
        else { return ([], emittedCells) }
        // +Δy (down) = UP arrows: negate the row delta for arrowEvents.
        return (arrowEvents(cols: 0, rows: -delta), newEmitted)
    }

    /// Turn an in-progress alt-screen vertical drag into vertical wheel-event runs (the Blink
    /// model): gain FIXED at 1.0 (one line-height of travel = one wheel event, about one line in the
    /// app), same incremental + flood-clamp accounting as `arrows`. Runs are `.up`/`.down` only;
    /// the App stamps each with the drag-point coordinate at encode time. Finger DOWN (+Δy) =
    /// wheel UP (scroll back), matching the arrows convention.
    public static func wheelEvents(totalDy: Double,
                                   cellHeight: Double,
                                   emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard let (delta, newEmitted) = signedCellDelta(totalDy: totalDy, cellHeight: cellHeight,
                                                        emittedCells: emittedCells, gain: 1.0)
        else { return ([], emittedCells) }
        return (arrowEvents(cols: 0, rows: -delta), newEmitted)
    }
}
