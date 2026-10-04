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

    private struct Sample: Sendable {
        var time: Double
        var point: GesturePoint
    }

    private enum State: Sendable {
        case idle
        /// One finger down, not yet a drag. `stoppedFling`: this touch stopped a fling, so its
        /// release is not a tap. `onHandle`: started on a selection handle (never long-presses).
        case pressed(start: GesturePoint, startTime: Double, handle: SelectionEnd?,
                     longPressEligible: Bool, stoppedFling: Bool, context: GestureContext)
        case longPressed
        case draggingHandle(anchor: GestureCell, last: GesturePoint, context: GestureContext)
        case swiping(start: GesturePoint, samples: [Sample], context: GestureContext)
        case scrolling(start: GesturePoint, emitted: Int, samples: [Sample], context: GestureContext)
        case flinging(velocity: Double, startTime: Double, lastTick: Double, emitted: Int,
                      at: GestureCell, context: GestureContext)
        case twoFinger(startTime: Double, start: GesturePoint, moved: Bool, context: GestureContext)
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
        case .draggingHandle: return "draggingHandle"
        case .swiping: return "swiping"
        case .scrolling: return "scrolling"
        case .flinging: return "flinging"
        case .twoFinger: return "twoFinger"
        }
    }

    /// The next time `tick(at:)` must be called, or nil when nothing is pending.
    public var nextDeadline: Double? {
        var deadlines: [Double] = []
        if case let .pressed(_, startTime, _, eligible, _, _) = state, eligible {
            deadlines.append(startTime + GestureThresholds.longPressDuration)
        }
        if let pendingTap { deadlines.append(pendingTap.deadline) }
        if case let .flinging(_, _, lastTick, _, _, _) = state {
            deadlines.append(lastTick + GestureThresholds.flingFrameInterval)
        }
        return deadlines.min()
    }

    public mutating func handle(_ event: TouchEvent, context: GestureContext) -> [GestureIntent] {
        switch event.phase {
        case .down: return touchDown(event, context)
        case .move: return touchMove(event)
        case .up: return touchUp(event)
        case .cancel: return touchCancel(event)
        }
    }

    public mutating func tick(at time: Double) -> [GestureIntent] {
        var out: [GestureIntent] = []
        if let pending = pendingTap, time >= pending.deadline {
            pendingTap = nil
            out.append(.tap(pending.cell))
        }
        switch state {
        case let .pressed(_, startTime, _, eligible, _, ctx)
            where eligible && time - startTime >= GestureThresholds.longPressDuration:
            state = .longPressed
            resetTapSequence()
            if ctx.screen == .plainTmux { out.append(.zoom) }
        case let .flinging(velocity, startTime, _, emitted, at, ctx):
            let momentum = ScrollMomentum(velocity: velocity)
            let t = time - startTime
            let step = Self.lineDelta(totalDy: momentum.offset(at: t), emitted: emitted, context: ctx)
            if step.delta != 0 { out.append(.scroll(lines: step.delta, at: at)) }
            if momentum.isFinished(at: t) {
                state = .idle
            } else {
                state = .flinging(velocity: velocity, startTime: startTime, lastTick: time,
                                  emitted: step.emitted, at: at, context: ctx)
            }
        default:
            break
        }
        return out
    }

    // MARK: events

    private mutating func touchDown(_ e: TouchEvent, _ ctx: GestureContext) -> [GestureIntent] {
        if e.touchCount >= 2 {
            var out: [GestureIntent] = []
            if case let .draggingHandle(_, last, _) = state {
                out.append(.endSelectionDrag(last, showMenu: false))
            }
            if case .twoFinger = state { return out }   // a third finger: keep the two-finger touch
            pendingTap = nil
            resetTapSequence()
            state = .twoFinger(startTime: e.time, start: e.point, moved: false, context: ctx)
            return out
        }
        let stoppedFling: Bool = { if case .flinging = state { return true }; return false }()
        let handle = GestureGeometry.handle(at: e.point, in: ctx)
        state = .pressed(start: e.point, startTime: e.time, handle: handle,
                         longPressEligible: handle == nil && !stoppedFling,
                         stoppedFling: stoppedFling, context: ctx)
        return []
    }

    private mutating func touchMove(_ e: TouchEvent) -> [GestureIntent] {
        switch state {
        case let .pressed(start, startTime, handle, eligible, stoppedFling, ctx):
            let distance = e.point.distance(to: start)
            if let handle, let selection = ctx.selection, distance >= GestureThresholds.deadZone {
                let anchor = handle == .start ? selection.end : selection.start
                state = .draggingHandle(anchor: anchor, last: e.point, context: ctx)
                return [Self.selectionIntent(anchor: anchor, point: e.point, context: ctx)]
            }
            switch DragAxisLock.resolve(dx: e.point.x - start.x, dy: e.point.y - start.y,
                                        isMultiWindowTmux: ctx.screen == .plainTmux && ctx.multiWindow) {
            case .pending:
                state = .pressed(start: start, startTime: startTime, handle: handle,
                                 longPressEligible: eligible && distance < GestureThresholds.longPressSlop,
                                 stoppedFling: stoppedFling, context: ctx)
                return []
            case .switchWindow:
                state = .swiping(start: start, samples: [Sample(time: e.time, point: e.point)], context: ctx)
                return []
            case .scroll:
                return scroll(to: e, start: start, emitted: 0, samples: [], context: ctx)
            }
        case let .draggingHandle(anchor, _, ctx):
            state = .draggingHandle(anchor: anchor, last: e.point, context: ctx)
            return [Self.selectionIntent(anchor: anchor, point: e.point, context: ctx)]
        case let .swiping(start, samples, ctx):
            state = .swiping(start: start,
                             samples: Self.trim(samples + [Sample(time: e.time, point: e.point)], now: e.time),
                             context: ctx)
            return []
        case let .scrolling(start, emitted, samples, ctx):
            return scroll(to: e, start: start, emitted: emitted, samples: samples, context: ctx)
        case let .twoFinger(startTime, start, moved, ctx):
            state = .twoFinger(startTime: startTime, start: start,
                               moved: moved || (e.touchCount >= 2 && e.point.distance(to: start) >= GestureThresholds.longPressSlop),
                               context: ctx)
            return []
        case .idle, .longPressed, .flinging:
            return []
        }
    }

    private mutating func touchUp(_ e: TouchEvent) -> [GestureIntent] {
        switch state {
        case let .pressed(start, _, _, _, stoppedFling, ctx):
            state = .idle
            return stoppedFling ? [] : tapReleased(at: start, time: e.time, context: ctx)
        case .longPressed:
            state = .idle
            return []
        case .draggingHandle:
            state = .idle
            return [.endSelectionDrag(e.point, showMenu: true)]
        case let .swiping(start, samples, ctx):
            state = .idle
            let all = Self.trim(samples + [Sample(time: e.time, point: e.point)], now: e.time)
            switch SwitchCommitDecision.resolve(dx: e.point.x - start.x, width: ctx.viewWidth,
                                                velocity: Self.velocity(all).x) {
            case let .commit(delta): return [.switchWindow(delta: delta)]
            case .springBack: return []
            }
        case let .scrolling(start, emitted, samples, ctx):
            let out = scroll(to: e, start: start, emitted: emitted, samples: samples, context: ctx)
            guard case let .scrolling(_, _, finalSamples, _) = state else { return out }
            let v = Self.velocity(finalSamples).y
            if ScrollMomentum(velocity: v).isFinished(at: 0) {
                state = .idle
            } else {
                state = .flinging(velocity: v, startTime: e.time, lastTick: e.time, emitted: 0,
                                  at: GestureGeometry.cell(at: e.point, in: ctx), context: ctx)
            }
            return out
        case let .twoFinger(startTime, _, moved, ctx):
            guard e.touchCount == 0 else { return [] }   // another finger is still down
            state = .idle
            if !moved, ctx.selection != nil,
               e.time - startTime <= GestureThresholds.twoFingerTapMaxDuration {
                return [.showMenu(e.point)]
            }
            return []
        case .idle, .flinging:
            return []
        }
    }

    private mutating func touchCancel(_ e: TouchEvent) -> [GestureIntent] {
        switch state {
        case let .draggingHandle(_, last, _):
            state = .idle
            return [.endSelectionDrag(last, showMenu: false)]
        case .flinging:
            return []   // no finger owns a fling
        default:
            state = .idle
            return []
        }
    }

    // MARK: scroll

    /// Advance a scroll to `e`, emitting whole lines; leaves the engine in `.scrolling`.
    private mutating func scroll(to e: TouchEvent, start: GesturePoint, emitted: Int,
                                 samples: [Sample], context ctx: GestureContext) -> [GestureIntent] {
        let step = Self.lineDelta(totalDy: e.point.y - start.y, emitted: emitted, context: ctx)
        state = .scrolling(start: start, emitted: step.emitted,
                           samples: Self.trim(samples + [Sample(time: e.time, point: e.point)], now: e.time),
                           context: ctx)
        return step.delta == 0 ? [] : [.scroll(lines: step.delta, at: GestureGeometry.cell(at: e.point, in: ctx))]
    }

    /// Lines to emit for a cumulative finger travel `totalDy`, given `emitted` so far.
    /// Truncates toward zero and clamps each emit to `maxLinesPerEmit`.
    private static func lineDelta(totalDy: Double, emitted: Int,
                                  context ctx: GestureContext) -> (delta: Int, emitted: Int) {
        guard ctx.cellHeight > 0 else { return (0, emitted) }
        let target = Int(totalDy * ctx.scrollGain / ctx.cellHeight)
        let limit = GestureThresholds.maxLinesPerEmit
        let delta = min(max(target - emitted, -limit), limit)
        return (delta, emitted + delta)
    }

    /// Keep samples inside the velocity window (at least the last two).
    private static func trim(_ samples: [Sample], now: Double) -> [Sample] {
        let recent = samples.filter { now - $0.time <= GestureThresholds.velocityWindow }
        return recent.count >= 2 ? recent : Array(samples.suffix(2))
    }

    /// Points per second between the first and last sample.
    private static func velocity(_ samples: [Sample]) -> (x: Double, y: Double) {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return (0, 0) }
        let dt = last.time - first.time
        return ((last.point.x - first.point.x) / dt, (last.point.y - first.point.y) / dt)
    }

    // MARK: selection

    private static func selectionIntent(anchor: GestureCell, point: GesturePoint,
                                        context ctx: GestureContext) -> GestureIntent {
        let moving = GestureGeometry.cell(at: point, in: ctx)
        let o = orderedSelection(a: (anchor.col, anchor.row), b: (moving.col, moving.row))
        return .setSelection(start: GestureCell(col: o.start.col, row: o.start.row),
                             end: GestureCell(col: o.end.col, row: o.end.row), loupe: point)
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
