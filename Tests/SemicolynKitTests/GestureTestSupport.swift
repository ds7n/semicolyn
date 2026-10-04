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

/// Drives a `GestureEngine` with one context and collects every intent in order.
struct GestureDriver {
    var engine = GestureEngine()
    var context: GestureContext
    private(set) var intents: [GestureIntent] = []

    init(_ context: GestureContext) { self.context = context }

    @discardableResult
    mutating func send(_ phase: TouchPhase, _ x: Double, _ y: Double, at t: Double, touches: Int = 1) -> [GestureIntent] {
        let out = engine.handle(TouchEvent(phase: phase, point: gp(x, y), time: t, touchCount: touches),
                                context: context)
        intents += out
        return out
    }
    @discardableResult mutating func down(_ x: Double, _ y: Double, at t: Double, touches: Int = 1) -> [GestureIntent] { send(.down, x, y, at: t, touches: touches) }
    @discardableResult mutating func move(_ x: Double, _ y: Double, at t: Double, touches: Int = 1) -> [GestureIntent] { send(.move, x, y, at: t, touches: touches) }
    /// `remaining` = touches still down AFTER this lift (0 for the last finger).
    @discardableResult mutating func up(_ x: Double, _ y: Double, at t: Double, remaining: Int = 0) -> [GestureIntent] { send(.up, x, y, at: t, touches: remaining) }
    @discardableResult
    mutating func tick(at t: Double) -> [GestureIntent] {
        let out = engine.tick(at: t)
        intents += out
        return out
    }
    /// Tick at every deadline until the engine is idle (nextDeadline nil) or `limit` passes.
    /// Returns the time of the last tick.
    @discardableResult
    mutating func drainTicks(limit: Double = 30) -> Double {
        var last = 0.0
        while let d = engine.nextDeadline, d <= limit {
            last = d
            tick(at: d)
        }
        return last
    }
}
