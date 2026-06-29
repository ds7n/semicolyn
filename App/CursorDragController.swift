// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Drives the cursor-placement drag for one SwiftTerm `TerminalView`: a faint halo at the
/// cursor + a halo-gated single-finger pan that runs `CursorDragEngine` and streams
/// synthesized arrow keys to the remote. Because it sends arrows (not mouse events) it works
/// under `set mouse=a`. One instance per `TerminalView`. macOS-CI-validated; not built on Linux.
///
/// Deferred to the Simulator feel-pass (uncertain SwiftTerm APIs / feel-tuning): the loupe
/// magnifier (needs `getChar` row text) and the offscreen `⌖` scrollback indicator (needs the
/// undocumented `scrolled(position:)` semantics).
final class CursorDragController: NSObject, UIGestureRecognizerDelegate {
    /// Halo radius in points (60pt diameter, per the locked design).
    static let haloRadius: CGFloat = 30

    let halo = CursorHaloView(frame: .zero)
    private weak var view: TerminalView?
    private let send: ([UInt8]) -> Void
    private var engine = CursorDragEngine()
    private var pan: UIPanGestureRecognizer?
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    /// Whether this pane is focused (multi-pane); halo + drag are live only when active.
    var active = true { didSet { refreshEnabled() } }
    /// Suppressed while iOS-native selection handles are visible (host-driven). NOTE: mouse-mode
    /// does NOT suppress — we synthesize arrows, so the drag works under `mouse=a`.
    var suppressed = false { didSet { refreshEnabled() } }

    private var lastPoint = CGPoint.zero
    private var emittedAny = false

    init(view: TerminalView, send: @escaping ([UInt8]) -> Void) {
        self.view = view
        self.send = send
        super.init()
    }

    /// Install the halo overlay + the halo-gated pan recognizer onto the view.
    func install() {
        guard let view else { return }
        halo.frame = view.bounds
        halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(halo)
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.maximumNumberOfTouches = 1
        p.delegate = self
        view.addGestureRecognizer(p)
        pan = p
        refresh()
    }

    func remove() {
        if let pan, let view { view.removeGestureRecognizer(pan) }
        pan = nil
        halo.removeFromSuperview()
    }

    func configure(color: UIColor) { halo.configure(color: color) }

    /// Recompute the halo position from the live cursor; hide when inactive/suppressed/offscreen.
    func refresh() {
        guard active, !suppressed, let view, let c = cursorCenter(in: view) else { halo.hide(); return }
        halo.place(center: c, radius: Self.haloRadius)
    }

    private func refreshEnabled() {
        pan?.isEnabled = active && !suppressed
        refresh()
    }

    // MARK: - Cursor geometry

    /// Live cursor cell → pane-local center point, or nil if offscreen / unmeasurable.
    private func cursorCenter(in view: TerminalView) -> CGPoint? {
        let term = view.getTerminal()
        let (cw, ch) = cellSize(of: view)
        guard cw > 0, ch > 0 else { return nil }
        let visibleRows = Int(Double(view.bounds.height) / ch)
        guard let p = cursorHaloPlacement(cursorCol: term.buffer.x, cursorRow: term.buffer.y,
                                          cellWidth: cw, cellHeight: ch,
                                          paneWidth: Double(view.bounds.width),
                                          paneHeight: Double(view.bounds.height),
                                          visibleRows: visibleRows,
                                          radius: Double(Self.haloRadius)) else { return nil }
        if p.isOffscreen { return nil }
        return CGPoint(x: p.centerX, y: p.centerY)
    }

    private func cellSize(of view: TerminalView) -> (Double, Double) {
        let f = view.font
        let w = Double("W".size(withAttributes: [.font: f]).width)
        let h = Double(f.lineHeight)
        return (w, h)
    }

    // MARK: - Gesture

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            engine.begin()
            emittedAny = false
            lastPoint = g.location(in: view)
            halo.setEngaged(true)
            haptics.impactOccurred()
        case .changed:
            let pt = g.location(in: view)
            let delta = (dx: Double(pt.x - lastPoint.x), dy: Double(pt.y - lastPoint.y))
            lastPoint = pt
            let v = g.velocity(in: view)
            let speed = Double(hypot(v.x, v.y))
            let (cw, ch) = cellSize(of: view)
            let move = engine.step(fingerDelta: delta, speed: speed, cellW: cw, cellH: ch, at: Date())
            emit(cols: move.cols, rows: move.rows)
            refresh()
        case .ended, .cancelled, .failed:
            engine.end()
            halo.setEngaged(false)
            if emittedAny { haptics.impactOccurred() } // lift haptic only after real movement
            refresh()
        default:
            break
        }
    }

    /// Translate a signed cell delta into arrow keystrokes and stream them to the remote.
    private func emit(cols: Int, rows: Int) {
        let runs = arrowEvents(cols: cols, rows: rows)
        guard !runs.isEmpty, let view else { return }
        emittedAny = true
        let app = view.getTerminal().applicationCursor
        var bytes: [UInt8] = []
        for run in runs {
            let one = encodeKey(.arrow(run.direction), modifiers: KeyModifiers(), applicationCursorKeys: app)
            for _ in 0 ..< run.count { bytes.append(contentsOf: one) }
        }
        send(bytes)
    }

    // MARK: - UIGestureRecognizerDelegate (halo-gated engage)

    /// Only claim the touch when it lands inside the halo on the focused, un-suppressed pane —
    /// otherwise yield so scroll / window-switch / selection proceed untouched.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard active, !suppressed, let view, let c = cursorCenter(in: view) else { return false }
        let pt = g.location(in: view)
        return hypot(pt.x - c.x, pt.y - c.y) <= Self.haloRadius
    }
}
