// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Converts a terminal area (points/pixels) plus measured monospace cell metrics
/// into a cell grid `(cols, rows)`. The single source of truth for the tmux
/// client size on rotation/layout: the container's bounds divided by the *real*
/// cell size (from the rendered font), not a hardcoded estimate.
///
/// Floors each axis — a partial trailing cell isn't usable — then clamps to a
/// minimum 1×1 (a terminal is never zero cells). Returns nil for degenerate input
/// (any non-positive dimension or cell), failing closed rather than emitting a
/// bogus size, consistent with the other pure terminal helpers.
public func terminalGrid(width: Double, height: Double,
                         cellWidth: Double, cellHeight: Double) -> (cols: Int, rows: Int)? {
    guard width > 0, height > 0, cellWidth > 0, cellHeight > 0 else { return nil }
    let cols = max(1, Int((width / cellWidth).rounded(.down)))
    let rows = max(1, Int((height / cellHeight).rounded(.down)))
    return (cols, rows)
}
