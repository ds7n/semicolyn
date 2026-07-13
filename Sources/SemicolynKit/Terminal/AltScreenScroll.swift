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

    public static func arrows(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard cellHeight > 0 else { return ([], emittedCells) }
        let target = Int(totalDy / cellHeight)
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
