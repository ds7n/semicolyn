// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One run of arrow-key presses in a single direction.
public struct ArrowRun: Equatable, Sendable {
    public let direction: ArrowDirection
    public let count: Int
    public init(direction: ArrowDirection, count: Int) {
        self.direction = direction
        self.count = count
    }
}

/// Map a signed `(cols, rows)` cell delta from `CursorDragEngine` into the arrow-key runs to
/// synthesize: +cols = Right, −cols = Left, +rows = Down, −rows = Up. Horizontal first, then
/// vertical; zero deltas produce no run. The App encodes each run via `encodeKey(.arrow(…))`.
public func arrowEvents(cols: Int, rows: Int) -> [ArrowRun] {
    var runs: [ArrowRun] = []
    if cols != 0 { runs.append(ArrowRun(direction: cols > 0 ? .right : .left, count: abs(cols))) }
    if rows != 0 { runs.append(ArrowRun(direction: rows > 0 ? .down : .up, count: abs(rows))) }
    return runs
}
