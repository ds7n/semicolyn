// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Every gesture threshold in one place (spec 2026-10-04, today's tuned values).
public enum GestureThresholds {
    /// Movement before a touch becomes a drag (Euclidean points).
    public static let deadZone: Double = DragAxisLock.deadZonePoints
    public static let longPressDuration: Double = 0.5
    /// Movement that disqualifies a long press.
    public static let longPressSlop: Double = 10
    /// Fingertip padding around a selection handle cell.
    public static let handleSlop: Double = 22
    /// Max time / distance between taps of one double or triple tap.
    public static let multiTapInterval: Double = 0.35
    public static let multiTapDistance: Double = 40
    public static let twoFingerTapMaxDuration: Double = 0.35
    /// Release velocity is measured over this trailing window.
    public static let velocityWindow: Double = 0.1
    public static let maxLinesPerEmit: Int = AltScreenScroll.maxCellsPerEmit
    public static let flingFrameInterval: Double = 1.0 / 60.0
}
