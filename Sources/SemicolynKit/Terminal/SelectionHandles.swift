// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which end of a selection a handle-drag grabs.
public enum SelectionEnd: Sendable {
    case start
    case end
}

/// A point in view content space (no CoreGraphics dependency, Linux-testable; the App layer
/// converts a `CGPoint` to/from this at the call boundary, mirroring `PaneRect`).
public struct SelectionHandlePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }
}

/// A cell's on-screen rect in view content space (no CoreGraphics dependency; the App layer
/// converts a `CGRect` to/from this, mirroring `PaneRect`).
public struct SelectionHandleRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Whether `point` falls within this rect after padding every edge outward by `slop`
    /// (touch tolerance). A negative `slop` shrinks the rect instead.
    func containsPadded(_ point: SelectionHandlePoint, slop: Double) -> Bool {
        let minX = x - slop, maxX = x + width + slop
        let minY = y - slop, maxY = y + height + slop
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// Pick which selection handle `point` is on, given each end's on-screen cell rect padded by
/// `slop` (touch tolerance). `start` wins if the padded rects overlap the point. Returns nil
/// when the point is on neither (the caller then treats the drag as content, not a handle drag).
public func hitTestHandle(point: SelectionHandlePoint, startRect: SelectionHandleRect,
                          endRect: SelectionHandleRect, slop: Double) -> SelectionEnd? {
    if startRect.containsPadded(point, slop: slop) { return .start }
    if endRect.containsPadded(point, slop: slop) { return .end }
    return nil
}

/// Normalize two grid positions so `start` precedes `end` in reading (row-major) order.
public func orderedSelection(a: (col: Int, row: Int), b: (col: Int, row: Int))
    -> (start: (col: Int, row: Int), end: (col: Int, row: Int)) {
    if a.row < b.row || (a.row == b.row && a.col <= b.col) { return (a, b) }
    return (b, a)
}
