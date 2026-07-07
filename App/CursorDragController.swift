// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Cursor-centric touch controller (replaces the halo). Installs a tap (reposition)
/// and a plain pan (scrub) on a focused, non-mouse-mode `TerminalView`. Long-press →
/// SwiftTerm native selection is a SEPARATE existing recognizer, left untouched; the
/// pan yields to it naturally (early finger movement → pan; stay still ~0.5s → the
/// long-press fires and selection wins).
final class CursorDragController: NSObject, UIGestureRecognizerDelegate {
    /// This pane is the focused one (only the focused pane gets cursor gestures).
    var active = false
    /// The pane is in mouse-reporting mode (`mouse=a`); suspend cursor gestures so
    /// taps/drags forward as SGR mouse events instead.
    var suppressed = false

    private weak var view: TerminalView?
    private let send: ([UInt8]) -> Void
    // `var` (not `let`): CursorDragEngine is a value type whose begin()/step()/end()
    // are `mutating` — a `let` would not compile.
    private var engine = CursorDragEngine()
    private var tap: UITapGestureRecognizer?
    private var pan: UIPanGestureRecognizer?
    private var lastPoint: CGPoint = .zero

    init(view: TerminalView, send: @escaping ([UInt8]) -> Void) {
        self.view = view
        self.send = send
        super.init()
        install()
    }

    private func install() {
        guard let view else { return }
        let t = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        t.delegate = self
        view.addGestureRecognizer(t)
        tap = t
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.delegate = self
        // Single-finger scrub only: a two-finger swipe stays a scroll, not a cursor
        // drag (matches the old controller; avoids fighting the terminal's scroll).
        p.maximumNumberOfTouches = 1
        view.addGestureRecognizer(p)
        pan = p
    }

    func remove() {
        if let view, let t = tap { view.removeGestureRecognizer(t) }
        if let view, let p = pan { view.removeGestureRecognizer(p) }
        tap = nil; pan = nil
    }

    // MARK: cell metrics

    private func cellSize(of view: TerminalView) -> (Double, Double) {
        let f = view.font
        let w = Double("W".size(withAttributes: [.font: f]).width)
        let h = Double(f.lineHeight)
        return (w, h)
    }

    // MARK: tap → reposition

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard active, !suppressed, let view else { return }
        let term = view.getTerminal()
        let (cw, ch) = cellSize(of: view)
        guard cw > 0, ch > 0 else { return }
        // The tap converts a VIEWPORT pixel to a cell, but the live cursor row
        // (buffer.y) is only viewport-relative when NOT scrolled into scrollback. If
        // the live cursor is scrolled off the visible viewport, `toRow - buffer.y`
        // spans two coordinate spaces → a bogus cross-row arrow run. Bail in that case
        // (mirrors the removed halo's `isOffscreen` guard). Same-viewport taps are fine.
        let visibleRows = Int(Double(view.bounds.height) / ch)
        guard visibleRows > 0, term.buffer.y >= 0, term.buffer.y < visibleRows else { return }
        let pt = g.location(in: view)
        let toCol = Int((Double(pt.x) / cw).rounded(.down))
        let toRow = Int((Double(pt.y) / ch).rounded(.down))
        let runs = cursorTapArrows(fromCol: term.buffer.x, fromRow: term.buffer.y,
                                   toCol: toCol, toRow: toRow)
        emitRuns(runs)
    }

    // MARK: pan → scrub (drag math unchanged)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard active, !suppressed, let view else { return }
        switch g.state {
        case .began:
            engine.begin(); lastPoint = g.location(in: view)
        case .changed:
            let pt = g.location(in: view)
            let delta = (dx: Double(pt.x - lastPoint.x), dy: Double(pt.y - lastPoint.y))
            lastPoint = pt
            let v = g.velocity(in: view)
            let speed = Double(hypot(v.x, v.y))
            let (cw, ch) = cellSize(of: view)
            let move = engine.step(fingerDelta: delta, speed: speed, cellW: cw, cellH: ch, at: Date())
            emit(cols: move.cols, rows: move.rows)
        case .ended, .cancelled, .failed:
            engine.end()
        default:
            break
        }
    }

    // MARK: emit

    private func emit(cols: Int, rows: Int) { emitRuns(arrowEvents(cols: cols, rows: rows)) }

    private func emitRuns(_ runs: [ArrowRun]) {
        guard !runs.isEmpty, let view else { return }
        let app = view.getTerminal().applicationCursor
        var bytes: [UInt8] = []
        for run in runs {
            let one = encodeKey(.arrow(run.direction), modifiers: KeyModifiers(), applicationCursorKeys: app)
            for _ in 0 ..< run.count { bytes.append(contentsOf: one) }
        }
        send(bytes)
    }

    // MARK: arbitration

    // Coexist with SwiftTerm's scroll + the tap, but NOT with a long-press: a
    // hold-then-drag must select (loupe + handles), not simultaneously scrub the
    // cursor. Yielding the pan to any long-press keeps "hold still → select, move →
    // scrub" mutually exclusive (spec's arbitration; the spec flagged simultaneity as
    // the field-test risk).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if other is UILongPressGestureRecognizer { return false }
        return true
    }
}
