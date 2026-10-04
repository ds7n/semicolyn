// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The single terminal gesture state machine (spec 2026-10-04). Pure and deterministic:
/// touch events and timer ticks (with their timestamps) in, `GestureIntent`s out. It never
/// reads a clock; `nextDeadline` tells the caller when to call `tick(at:)`.
public struct GestureEngine: Sendable {
    private struct PendingTap: Sendable {
        var deadline: Double
        var cell: GestureCell
    }

    private enum State: Sendable {
        case idle
        case pressed(start: GesturePoint, startTime: Double, longPressEligible: Bool, context: GestureContext)
        case longPressed
    }

    private var state: State = .idle
    private var tapCount = 0
    private var lastTapTime: Double?
    private var lastTapPoint: GesturePoint?
    private var pendingTap: PendingTap?

    public init() {}

    public var stateName: String {
        switch state {
        case .idle: return "idle"
        case .pressed: return "pressed"
        case .longPressed: return "longPressed"
        }
    }

    /// The next time `tick(at:)` must be called, or nil when nothing is pending.
    public var nextDeadline: Double? {
        var deadlines: [Double] = []
        if case let .pressed(_, startTime, eligible, _) = state, eligible {
            deadlines.append(startTime + GestureThresholds.longPressDuration)
        }
        if let pendingTap { deadlines.append(pendingTap.deadline) }
        return deadlines.min()
    }

    public mutating func handle(_ event: TouchEvent, context: GestureContext) -> [GestureIntent] {
        switch event.phase {
        case .down:
            state = .pressed(start: event.point, startTime: event.time, longPressEligible: true, context: context)
            return []
        case .move:
            if case let .pressed(start, startTime, eligible, ctx) = state {
                let stillEligible = eligible && event.point.distance(to: start) < GestureThresholds.longPressSlop
                state = .pressed(start: start, startTime: startTime, longPressEligible: stillEligible, context: ctx)
            }
            return []
        case .up:
            guard case let .pressed(start, _, _, ctx) = state else { state = .idle; return [] }
            state = .idle
            return tapReleased(at: start, time: event.time, context: ctx)
        case .cancel:
            state = .idle
            return []
        }
    }

    public mutating func tick(at time: Double) -> [GestureIntent] {
        var out: [GestureIntent] = []
        if let pending = pendingTap, time >= pending.deadline {
            pendingTap = nil
            out.append(.tap(pending.cell))
        }
        if case let .pressed(_, startTime, eligible, ctx) = state,
           eligible, time - startTime >= GestureThresholds.longPressDuration {
            state = .longPressed
            resetTapSequence()
            if ctx.screen == .plainTmux { out.append(.zoom) }
        }
        return out
    }

    // MARK: taps

    private mutating func tapReleased(at p: GesturePoint, time t: Double,
                                      context ctx: GestureContext) -> [GestureIntent] {
        let continues: Bool = {
            guard tapCount < 3, let lastTime = lastTapTime, let lastPoint = lastTapPoint else { return false }
            return t - lastTime <= GestureThresholds.multiTapInterval
                && p.distance(to: lastPoint) <= GestureThresholds.multiTapDistance
        }()
        tapCount = continues ? tapCount + 1 : 1
        lastTapTime = t
        lastTapPoint = p
        let cell = GestureGeometry.cell(at: p, in: ctx)
        switch tapCount {
        case 1:
            var out: [GestureIntent] = [.restoreKeyboard]
            if ctx.selection != nil {
                out.append(GestureGeometry.isInsideSelection(cell, in: ctx) ? .showMenu(p) : .clearSelection)
                return out
            }
            switch (ctx.screen, ctx.mode) {
            case (.plainTmux, _):
                out.append(.tap(cell))
            case (.rawShell, .local):
                pendingTap = PendingTap(deadline: t + GestureThresholds.multiTapInterval, cell: cell)
            case (.rawShell, .app):
                if ctx.appMouseOn {
                    pendingTap = PendingTap(deadline: t + GestureThresholds.multiTapInterval, cell: cell)
                }
            }
            return out
        case 2:
            pendingTap = nil
            return [.selectWord(cell, at: p)]
        default:
            return [.selectLine(row: cell.row, at: p)]
        }
    }

    private mutating func resetTapSequence() {
        tapCount = 0
        lastTapTime = nil
        lastTapPoint = nil
        pendingTap = nil
    }
}
