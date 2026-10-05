// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import UIKit.UIGestureRecognizerSubclass
import SemicolynKit

/// The terminal's ONLY touch recognizer besides pinch (spec 2026-10-04). It never begins or
/// claims touches (`cancelsTouchesInView = false`); it feeds every touch, converted to
/// viewport points, into the pure Kit `GestureEngine` and hands the resulting intents to the
/// executor. A display-link timer runs only while the engine has a deadline (long press,
/// a held single tap, fling frames).
@MainActor
final class TerminalTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let makeContext: () -> GestureContext?
    /// Intents plus the engine transition they came from and the engine's `lastReason`.
    private let onIntents: ([GestureIntent], _ from: String, _ to: String, _ reason: String) -> Void
    private var engine = GestureEngine()
    private var context: GestureContext?
    private var active: Set<UITouch> = []
    private var displayLink: CADisplayLink?

    init(makeContext: @escaping () -> GestureContext?,
         onIntents: @escaping ([GestureIntent], _ from: String, _ to: String, _ reason: String) -> Void) {
        self.makeContext = makeContext
        self.onIntents = onIntents
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        name = "ours.touchEngine"
        // Its own delegate, so it always recognizes simultaneously with every other
        // recognizer: when the pinch begins, UIKit must not force this recognizer to fail
        // mid-sequence (it observes; the second finger already cancels one-finger gestures
        // inside the engine).
        delegate = self
    }

    /// Never excluded by (or excluding) another recognizer: see `delegate = self` in `init`.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// Invalidate the timer (call when the terminal is torn down; the display link retains us).
    func stopTimers() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if active.isEmpty {
            context = makeContext()   // snapshot once per touch sequence
            // Logged next to the `touch` replay lines so a device log replays with its context.
            if let context { DebugLog.shared.log(.gesture, context.logLine) }
        }
        active.formUnion(touches)
        feed(.down, point: currentPoint(), time: event.timestamp, count: active.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        feed(.move, point: currentPoint(), time: event.timestamp, count: active.count)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let p = currentPoint()
        active.subtract(touches)
        feed(.up, point: p, time: event.timestamp, count: active.count)
        if active.isEmpty { state = .failed }   // never claims touches; resets for the next sequence
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let p = currentPoint()
        active.subtract(touches)
        feed(.cancel, point: p, time: event.timestamp, count: active.count)
        if active.isEmpty { state = .failed }
    }

    /// Only clears per-sequence bookkeeping: the engine (multi-tap memory, fling) persists.
    /// If UIKit resets us while a sequence is still in flight (forced to fail by another
    /// recognizer), feed the engine a `.cancel` first so it is never stranded in `pressed`
    /// (where its deadline could fire a spurious long-press zoom).
    override func reset() {
        super.reset()
        if !active.isEmpty, context != nil {
            feed(.cancel, point: currentPoint(), time: CACurrentMediaTime(), count: 0)
        }
        active.removeAll()
        context = nil
    }

    // MARK: engine

    private func feed(_ phase: TouchPhase, point: GesturePoint, time: TimeInterval, count: Int) {
        guard let ctx = context else { return }
        let event = TouchEvent(phase: phase, point: point, time: time, touchCount: count)
        DebugLog.shared.log(.gesture, event.replayLine)
        let from = engine.stateName
        let intents = engine.handle(event, context: ctx)
        onIntents(intents, from, engine.stateName, engine.lastReason)
        scheduleTimer()
    }

    private func scheduleTimer() {
        if engine.nextDeadline == nil {
            stopTimers()
        } else if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Display-link frames use `CACurrentMediaTime()`, the same clock as `UIEvent.timestamp`.
    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let deadline = engine.nextDeadline, now >= deadline {
            let from = engine.stateName
            let intents = engine.tick(at: now)
            if !intents.isEmpty || from != engine.stateName {
                onIntents(intents, from, engine.stateName, engine.lastReason)
            }
        }
        scheduleTimer()
    }

    // MARK: coordinates

    /// Viewport point of the active touch (centroid for two or more), measured in the
    /// terminal's SUPERVIEW minus the terminal's frame origin, so it is independent of the
    /// scroll view's content offset.
    private func currentPoint() -> GesturePoint {
        guard !active.isEmpty else { return GesturePoint(x: 0, y: 0) }
        var sx = 0.0, sy = 0.0
        for t in active {
            let p = viewportPoint(t)
            sx += p.x; sy += p.y
        }
        let n = Double(active.count)
        return GesturePoint(x: sx / n, y: sy / n)
    }

    private func viewportPoint(_ touch: UITouch) -> GesturePoint {
        guard let view, let superview = view.superview else {
            let p = touch.location(in: self.view)
            return GesturePoint(x: Double(p.x), y: Double(p.y))
        }
        let p = touch.location(in: superview)
        return GesturePoint(x: Double(p.x - view.frame.minX), y: Double(p.y - view.frame.minY))
    }
}
