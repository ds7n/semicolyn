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

    public static func arrows(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard cellHeight > 0 else { return ([], emittedCells) }
        let target = Int(totalDy * scrollGain / cellHeight)
        var delta = target - emittedCells
        if delta == 0 { return ([], emittedCells) }
        // Clamp magnitude to the per-emit cap (preserve sign).
        if delta > maxCellsPerEmit { delta = maxCellsPerEmit }
        if delta < -maxCellsPerEmit { delta = -maxCellsPerEmit }
        // +Δy (down) = UP arrows: negate the row delta for arrowEvents.
        let runs = arrowEvents(cols: 0, rows: -delta)
        return (runs, emittedCells + delta)
    }
}
