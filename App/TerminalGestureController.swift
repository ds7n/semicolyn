// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Owns the terminal touch map for a single `TerminalView`, replacing SwiftTerm's
/// built-in tap/long-press recognizers. Single-finger vertical drag scrolls via the
/// terminal's NATIVE `UIScrollView` pan (kept enabled — we do not fight it); a
/// horizontal drag on that same native pan switches tmux windows (one per drag, on
/// release, via `GestureClassifier` + the mount's clamp); single tap places the cursor;
/// double/triple-tap word/line-select; long-press zooms the tmux pane; two-finger
/// tap shows the edit menu. A mouse-reporting pane (`mouse=a`) yields: we set
/// `allowMouseReporting = true` and let SwiftTerm forward events (our recognizers
/// still installed but no-op via the `mouseReportingActive` guard).
///
/// SwiftTerm's own tap/long-press/pan recognizers are added via plain
/// `addGestureRecognizer` calls but never stored behind a public accessor (its
/// `disableMousePanGesture()` / `disableSelectionPanGesture()` helpers are
/// `internal`, not `public`, in the pinned SwiftTerm release — not reachable from
/// this module). We disable everything SwiftTerm has installed by scanning
/// `terminalView.gestureRecognizers` for recognizers that are not ours, which also
/// covers its two pan recognizers on the rare case they're already attached at
/// controller-init time.
@MainActor
final class TerminalGestureController: NSObject, UIGestureRecognizerDelegate {
    struct Callbacks {
        let isMultiWindowTmux: () -> Bool
        let onSwitchWindow: (Int) -> Void
        let onLongPressZoom: () -> Void
        let onPlaceCursor: (_ toCol: Int, _ toRow: Int) -> Void
        let mouseReportingActive: () -> Bool
        let hasSelection: () -> Bool
        let clearSelection: () -> Void
    }

    private weak var terminalView: TerminalView?
    private let callbacks: Callbacks

    // Our recognizers (kept so we can identify + remove them, and so the delegate can
    // tell ours apart from SwiftTerm's). Note: vertical scroll is NOT one of ours — it
    // stays on the terminal's native UIScrollView pan; we only add ourselves as an extra
    // target on it (see `handleScrollViewPan`) for the horizontal window-switch.
    private var ours: [UIGestureRecognizer] = []
    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var tripleTap: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!
    private var twoFingerTap: UITapGestureRecognizer!
    private var editMenu: UIEditMenuInteraction!

    init(terminalView: TerminalView, callbacks: Callbacks) {
        self.terminalView = terminalView
        self.callbacks = callbacks
        super.init()
        disableSwiftTermRecognizers(on: terminalView)
        installOurRecognizers(on: terminalView)
    }

    // MARK: Setup

    private func disableSwiftTermRecognizers(on view: TerminalView) {
        // SwiftTerm's tap/double/triple/long-press recognizers are attached via plain
        // `addGestureRecognizer` calls with no public stored handle → disable everything
        // currently attached that is NOT ours. Ours aren't installed yet at this point,
        // so every existing recognizer here is SwiftTerm's (or a sibling like pinch,
        // which the mount installs AFTER this controller — order matters, see mount).
        //
        // CRUCIAL EXCEPTION: `TerminalView` is a `UIScrollView` and scrolls via its
        // INHERITED `panGestureRecognizer`. We must NOT disable it — doing so kills
        // native scrolling AND leaves `isTracking` false, so SwiftTerm's
        // `syncYDispFromContentOffset` (gated on `isTracking`) never updates scrollback.
        // We keep native scroll and ride this same recognizer for the window-switch
        // decision (see `handleScrollViewPan`).
        for gr in view.gestureRecognizers ?? []
        where !ours.contains(gr) && gr !== view.panGestureRecognizer {
            gr.isEnabled = false
        }
        DebugLog.shared.log(.gesture, "sweep: disabled \(view.gestureRecognizers?.filter { !$0.isEnabled }.count ?? 0) recognizers; nativePan kept=\(view.panGestureRecognizer.isEnabled)")
    }

    private func installOurRecognizers(on view: TerminalView) {
        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.delegate = self

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.delegate = self

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self

        twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self

        // Tap disambiguation: single waits for double to fail, double waits for triple.
        // single-tap deliberately requires ONLY double (not triple) — so cursor
        // placement resolves after a single failed-double window, not the full
        // single→double→triple chain. Keeps all three gestures.
        singleTap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        editMenu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(editMenu)

        ours = [singleTap, doubleTap, tripleTap, longPress, twoFingerTap]
        for gr in ours { view.addGestureRecognizer(gr) }

        // Vertical scrolling stays NATIVE (the inherited UIScrollView pan, kept enabled
        // by the sweep). We ride that same recognizer to detect a horizontal drag =
        // tmux window switch, so we never fight the scroll view with a competing pan.
        view.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))

        // Tap snappiness: UIScrollView delays content-touch delivery (~150ms) to first
        // decide whether a touch is the start of a scroll, which made single-tap cursor
        // placement feel sluggish. Deliver touches immediately — our tap recognizers no
        // longer wait on the scroll-detection window. (The pan still recognizes a drag
        // fine; only the initial delivery delay is removed.)
        view.delaysContentTouches = false
    }

    func detach() {
        guard let view = terminalView else { return }
        view.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollViewPan(_:)))
        for gr in ours { view.removeGestureRecognizer(gr) }
        view.removeInteraction(editMenu)
        ours = []
    }

    // MARK: Cell geometry

    /// Convert a point in the terminal view to a (col, row) cell using the terminal's
    /// current grid and the view's content size (SwiftTerm lays cells out uniformly).
    private func cell(at point: CGPoint, in view: TerminalView) -> (col: Int, row: Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        let rows = max(term.rows, 1)
        let cellW = view.bounds.width / CGFloat(cols)
        let cellH = view.bounds.height / CGFloat(rows)
        guard cellW > 0, cellH > 0 else { return (0, 0) }
        // `point` is `gesture.location(in: view)`. SwiftTerm's own tap-hit math
        // (`calculateTapHit`) maps this DIRECTLY: row = point.y / cellHeight, with NO
        // `contentOffset` arithmetic — the gesture point is already in the coordinate
        // space SwiftTerm's selection/cursor APIs expect. The previous `+ contentOffset.y`
        // / `- Int(contentOffset.y / cellH)` juggling double-counted the offset and left a
        // rounding residue that grew with scroll distance (device bug: double/triple-tap
        // selected a row far above the tap once the buffer had scrolled). Match SwiftTerm.
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        let row = min(rows - 1, max(0, Int(point.y / cellH)))
        return (col, row)
    }

    // MARK: Handlers

    /// Rides the terminal's NATIVE UIScrollView pan (we added ourselves as an extra
    /// target). Vertical drags are handled by the scroll view itself (native scroll,
    /// inertia, correct `isTracking`/scrollback) — we do nothing for them. We only look
    /// for a horizontal-dominant drag in multi-window tmux and, on release, fire a
    /// one-per-drag window switch. `GestureClassifier` decides from the cumulative
    /// translation; a vertical or single-window drag classifies as scroll and we no-op.
    @objc private func handleScrollViewPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }  // mouse app: SwiftTerm forwards
        DebugLog.shared.log(.gesture, "gr:scrollPan state=\(g.state.rawValue) t=\(g.translation(in: view)) mouseReporting=\(callbacks.mouseReportingActive())")
        guard g.state == .ended || g.state == .cancelled else { return }
        let t = g.translation(in: view)
        let decision = GestureClassifier.classify(
            dx: Double(t.x), dy: Double(t.y),
            isMultiWindowTmux: callbacks.isMultiWindowTmux())
        if case .switchWindow(let delta) = decision {
            callbacks.onSwitchWindow(delta)
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }
        let action = tapAction(hasSelection: callbacks.hasSelection())
        switch action {
        case .clearSelection:
            callbacks.clearSelection()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=clear")
        case .placeCursor:
            let p = g.location(in: view)
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.row)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.row))")
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        let p = g.location(in: view)
        let (col, row) = cell(at: p, in: view)
        // Word-select: expand from the tapped cell across non-space runs on that row.
        let (start, end) = wordBounds(col: col, row: row, in: view)
        DebugLog.shared.log(.gesture, "sel:before hasActive=\(view.hasActiveSelection)")
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        DebugLog.shared.log(.gesture, "sel:after set (\(start),\(row))-(\(end),\(row)) hasActive=\(view.hasActiveSelection)")
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        let p = g.location(in: view)
        let (_, row) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        DebugLog.shared.log(.gesture, "sel:before hasActive=\(view.hasActiveSelection)")
        view.setSelectionRange(start: Position(col: 0, row: row),
                               end: Position(col: cols - 1, row: row))
        DebugLog.shared.log(.gesture, "sel:after set (0,\(row))-(\(cols - 1),\(row)) hasActive=\(view.hasActiveSelection)")
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: g.view))")
        guard g.state == .began else { return }
        callbacks.onLongPressZoom()
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        presentEditMenu(at: g.location(in: view), in: view)
    }

    // MARK: Selection helpers

    /// Word bounds on a row: walk left/right from `col` over non-space glyphs.
    private func wordBounds(col: Int, row: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func isWordChar(_ c: Int) -> Bool {
            guard let cd = term.getCharData(col: c, row: row) else { return false }
            let ch = cd.getCharacter()   // CharData.getCharacter(); matches SwiftTermEchoOracle usage
            return !(ch == " " || ch == "\t" || ch == "\0")
        }
        var lo = min(max(col, 0), cols - 1)
        var hi = lo
        while lo > 0, isWordChar(lo - 1) { lo -= 1 }
        while hi < cols - 1, isWordChar(hi + 1) { hi += 1 }
        return (lo, hi)
    }

    private func presentEditMenu(at point: CGPoint, in view: TerminalView) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenu.presentEditMenu(with: config)
    }

    // MARK: UIGestureRecognizerDelegate

    // Let our recognizers coexist with the mount's pinch (pinch is 2-finger, our pan is
    // 1-finger; allow simultaneous so a stray second finger doesn't kill scroll).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: UIEditMenuInteractionDelegate

extension TerminalGestureController: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view = terminalView else { return UIMenu(children: suggestedActions) }
        var items: [UIMenuElement] = []
        if view.hasActiveSelection {
            items.append(UIAction(title: "Copy") { [weak view] _ in view?.copy(nil) })
        }
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste") { [weak view] _ in view?.paste(nil) })
        }
        return UIMenu(children: items.isEmpty ? suggestedActions : items)
    }
}
