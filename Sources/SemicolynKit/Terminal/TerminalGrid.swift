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

/// The terminal child's height on the raw path, derived from WINDOW-SPACE keybar geometry rather
/// than from the container's own `bounds` (2026-08-09, after ~7 fixes that all subtracted from an
/// unstable `bounds`). The device forensics proved `bounds` is ambiguous, sometimes it already
/// excludes the keybar band (~431 after an app-switch), sometimes it includes it (~499 on first
/// connect), and NO same-window height signal (bounds / keyboardLayoutGuide / safeAreaInsets)
/// distinguishes the two. The ONE signal that does is the keybar accessory's REAL top edge in
/// window space (`accessoryTopY`, from `window.convert(accessory.frame, from: accessory.superview)`)
/// relative to the container's own top in window space (`containerTopY`, from
/// `container.convert(.zero, to: window)`): the child must reach exactly the keybar's top, so its
/// height is `accessoryTopY - containerTopY`, regardless of what `bounds` "means".
///
/// The accessory is hosted in a SEPARATE UIKit window and lays out on its own cycle, so a value
/// read during the keybar/keyboard animation can be transient garbage (device: `accessoryTopY`
/// briefly == the window height). This returns `nil` (caller must hold its last-known-good height)
/// unless the inputs are a trustworthy INTERIOR value: first responder, a positive accessory
/// height, and a keybar top that lies within the container's own vertical extent
/// (`containerTopY < accessoryTopY <= containerTopY + containerHeight`). The upper bound rejects
/// the mid-animation "accessory at the window bottom" transient; the lower bound rejects a keybar
/// top above the container (nonsensical). Pure; unit-tested with the build-124 device numbers.
///
/// - Returns: the child height in points, or `nil` when the geometry is not trustworthy this pass.
public func rawTerminalChildHeight(accessoryTopY: Double?,
                                   containerTopY: Double,
                                   containerHeight: Double,
                                   accessoryHeight: Double,
                                   isFirstResponder: Bool) -> Double? {
    guard isFirstResponder, accessoryHeight > 0, let accTop = accessoryTopY else { return nil }
    // The keybar top must sit strictly below the container top and no lower than the container's
    // own bottom edge. Outside that interval the converted frame is a cross-window animation
    // transient (or a stale/degenerate value) and must not drive layout.
    guard accTop > containerTopY, accTop <= containerTopY + containerHeight else { return nil }
    let h = accTop - containerTopY
    return h > 0 ? h : nil
}
