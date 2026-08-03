// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The center point for a floating magnifier loupe of `loupeWidth` x `loupeHeight`, placed
/// `verticalOffset` points above `finger`, clamped so the whole loupe stays inside a
/// `(boundsWidth, boundsHeight)` box anchored at the origin (so it never leaves the visible
/// pane, even at the edges where the finger is near a border).
///
/// Plain-Double geometry (no CoreGraphics dependency, Linux-testable), mirroring the
/// `SelectionHandlePoint`/`SelectionHandleRect` idiom: the App layer converts
/// `CGPoint`/`CGRect`/`CGSize` to/from these at the call boundary.
public func loupeCenter(finger: SelectionHandlePoint, boundsWidth: Double, boundsHeight: Double,
                        loupeWidth: Double, loupeHeight: Double,
                        verticalOffset: Double) -> SelectionHandlePoint {
    let halfW = loupeWidth / 2
    let halfH = loupeHeight / 2
    let rawX = finger.x
    let rawY = finger.y - verticalOffset
    let x = min(max(rawX, halfW), boundsWidth - halfW)
    let y = min(max(rawY, halfH), boundsHeight - halfH)
    return SelectionHandlePoint(x: x, y: y)
}
