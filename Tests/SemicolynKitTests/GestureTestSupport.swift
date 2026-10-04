// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
@testable import SemicolynKit

/// Shared fixtures for gesture tests. Grid: 10pt x 20pt cells, 40 cols x 30 rows, top
/// visible absolute row 100, view 400pt wide. So viewport point (55, 45) is col 5, viewport
/// row 2, absolute row 102.
func gestureContext(screen: GestureScreen = .plainTmux,
                    mode: GestureMode = .app,
                    appMouseOn: Bool = true,
                    multiWindow: Bool = true,
                    selection: GestureSelection? = nil,
                    cellWidth: Double = 10,
                    cellHeight: Double = 20,
                    viewWidth: Double = 400,
                    scrollGain: Double = 1.0) -> GestureContext {
    GestureContext(screen: screen, mode: mode, appMouseOn: appMouseOn, multiWindow: multiWindow,
                   selection: selection, cellWidth: cellWidth, cellHeight: cellHeight,
                   cols: 40, rows: 30, topRow: 100, viewWidth: viewWidth, scrollGain: scrollGain)
}

func gp(_ x: Double, _ y: Double) -> GesturePoint { GesturePoint(x: x, y: y) }
func gc(_ col: Int, _ row: Int) -> GestureCell { GestureCell(col: col, row: row) }
