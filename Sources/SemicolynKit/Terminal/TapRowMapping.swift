// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Maps a tap to a terminal SCREEN row (0..<rows).
///
/// The gesture point comes from `UIGestureRecognizer.location(in: terminalView)`, and the
/// terminal view is a `UIScrollView`, so that point is in CONTENT space (it includes the
/// scroll offset). SwiftTerm's own hit-test (`calculateTapHit`) and its selection /
/// `getCharData` APIs operate in VIEWPORT space: a screen row in 0..<rows, from which
/// `getLine` adds `buffer.yDisp` itself. So the correct mapping subtracts the scroll offset
/// (content to viewport) and does NOT add `yDisp` (adding it would double-count, the prior
/// "row far above the tap" bug).
public struct TapRowMapping: Sendable {
    public static func row(contentY: Double, contentOffsetY: Double,
                           cellHeight: Double, rows: Int) -> Int {
        guard cellHeight > 0, rows > 0 else { return 0 }
        let viewportY = contentY - contentOffsetY
        let r = Int(viewportY / cellHeight)
        return min(rows - 1, max(0, r))
    }
}
