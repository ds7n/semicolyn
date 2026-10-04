// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A point in terminal VIEWPORT coordinates (points; origin = top-left of the visible grid,
/// independent of scrollback position).
public struct GesturePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public func distance(to other: GesturePoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A terminal cell. `row` is an ABSOLUTE buffer row (top visible row + viewport row), the
/// row space SwiftTerm's selection uses.
public struct GestureCell: Equatable, Sendable {
    public var col: Int
    public var row: Int
    public init(col: Int, row: Int) { self.col = col; self.row = row }
}

public enum TouchPhase: String, Equatable, Sendable { case down, move, up, cancel }

/// One touch event. `time` is seconds on a monotonic clock. `touchCount`: for `down`/`move`,
/// the number of fingers on screen; for `up`/`cancel`, the number still down AFTER the event
/// (0 when the last finger lifts). For two or more fingers, `point` is their centroid.
public struct TouchEvent: Equatable, Sendable {
    public var phase: TouchPhase
    public var point: GesturePoint
    public var time: Double
    public var touchCount: Int
    public init(phase: TouchPhase, point: GesturePoint, time: Double, touchCount: Int) {
        self.phase = phase; self.point = point; self.time = time; self.touchCount = touchCount
    }
}

public enum GestureScreen: Equatable, Sendable { case rawShell, plainTmux }

/// `local`: shell on its normal screen. `app`: alternate screen or app-requested mouse
/// (plain tmux is always `app`).
public enum GestureMode: Equatable, Sendable { case local, app }

/// The current selection, INCLUSIVE at both ends, absolute rows.
public struct GestureSelection: Equatable, Sendable {
    public var start: GestureCell
    public var end: GestureCell
    public init(start: GestureCell, end: GestureCell) { self.start = start; self.end = end }
}

/// Snapshot of everything the engine's decisions need, taken at touch-down.
public struct GestureContext: Equatable, Sendable {
    public var screen: GestureScreen
    public var mode: GestureMode
    /// The foreground app (or tmux) has mouse reporting on.
    public var appMouseOn: Bool
    /// Plain tmux with more than one window (enables the window swipe).
    public var multiWindow: Bool
    public var selection: GestureSelection?
    public var cellWidth: Double
    public var cellHeight: Double
    public var cols: Int
    public var rows: Int
    /// Absolute buffer row shown at the top of the viewport.
    public var topRow: Int
    public var viewWidth: Double
    /// Lines per cell-height of finger travel (1.0, or `AltScreenScroll.scrollGain` for
    /// arrow / page-key scrolling).
    public var scrollGain: Double

    public init(screen: GestureScreen, mode: GestureMode, appMouseOn: Bool, multiWindow: Bool,
                selection: GestureSelection?, cellWidth: Double, cellHeight: Double,
                cols: Int, rows: Int, topRow: Int, viewWidth: Double, scrollGain: Double) {
        self.screen = screen; self.mode = mode; self.appMouseOn = appMouseOn
        self.multiWindow = multiWindow; self.selection = selection
        self.cellWidth = cellWidth; self.cellHeight = cellHeight
        self.cols = cols; self.rows = rows; self.topRow = topRow
        self.viewWidth = viewWidth; self.scrollGain = scrollGain
    }
}

/// What should happen, not how. The App's executor performs these.
public enum GestureIntent: Equatable, Sendable {
    /// Focus the terminal / re-show the keyboard if it is hidden (no-op when visible).
    case restoreKeyboard
    /// A single tap: tmux click or pane cycle, raw cursor move, or app mouse click.
    case tap(GestureCell)
    case selectWord(GestureCell, at: GesturePoint)
    case selectLine(row: Int, at: GesturePoint)
    case clearSelection
    case showMenu(GesturePoint)
    /// Handle drag: the new selection (ordered) and where to show the magnifier.
    case setSelection(start: GestureCell, end: GestureCell, loupe: GesturePoint)
    case endSelectionDrag(GesturePoint, showMenu: Bool)
    case switchWindow(delta: Int)
    /// Positive `lines` = finger moved down = reveal OLDER content.
    case scroll(lines: Int, at: GestureCell)
    case zoom
}
