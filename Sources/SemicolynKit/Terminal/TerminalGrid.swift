// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Converts a terminal area (points/pixels) plus measured monospace cell metrics
/// into a cell grid `(cols, rows)`. The single source of truth for the tmux
/// client size on rotation/layout: the container's bounds divided by the *real*
/// cell size (from the rendered font), not a hardcoded estimate.
///
/// Floors each axis, a partial trailing cell isn't usable, then clamps to a
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

/// The terminal-usable height: the container's raw height minus the height the
/// keybar/keyboard accessory reserves at the bottom. Device #1 (2026-07-20): the
/// grid was fed raw container bounds that included the keybar, so the terminal
/// rendered behind the bar and the keyboard. `keybarHeight <= 0` means no pane is
/// first responder (the sentinel `-1` from `firstResponderKeybarHeight()` when the
/// keyboard is down, so no accessory is shown) -> subtract nothing. Floors at 0 so
/// a keybar taller than the area never yields a negative height (`terminalGrid`
/// then fail-closes on the non-positive input).
public func visibleTerminalHeight(rawHeight: Double, keybarHeight: Double) -> Double {
    guard keybarHeight > 0 else { return rawHeight }
    return max(0, rawHeight - keybarHeight)
}

/// The terminal-usable height when the keyboard/keybar top is known from UIKit's
/// `keyboardLayoutGuide`. `keyboardTopY` is the guide's `layoutFrame.minY` in the container's
/// coordinate space (the pane bottom sits exactly there); `nil` when the keyboard is down or the
/// guide has no usable frame. Returns `keyboardTopY` when it is a valid interior value
/// (`0 < keyboardTopY <= rawHeight`), else the full `rawHeight` (fail open: keyboard-down or a
/// bogus guide value must never yield a zero/negative pane). This is preferred over
/// `visibleTerminalHeight(rawHeight:keybarHeight:)` because it uses the keybar's REAL position
/// (which re-lays-out after an app-switch) instead of a measured height that only aligns on first
/// connect.
public func usableHeightFromKeyboardTop(rawHeight: Double, keyboardTopY: Double?) -> Double {
    guard let top = keyboardTopY, top > 0, top <= rawHeight else { return rawHeight }
    return top
}
