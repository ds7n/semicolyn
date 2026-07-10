// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Owns the terminal touch map for a single `TerminalView`, replacing SwiftTerm's
/// built-in recognizers. Single-finger vertical drag scrolls (`contentOffset`);
/// horizontal drag switches tmux windows (one per drag, on release, via
/// `GestureClassifier` + the mount's clamp); single tap places the cursor;
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
    }

    private weak var terminalView: TerminalView?
    private let callbacks: Callbacks

    // Our recognizers (kept so we can identify + remove them, and so the delegate can
    // tell ours apart from SwiftTerm's).
    private var ours: [UIGestureRecognizer] = []
    /// Last cumulative vertical pan translation (points), for computing the per-tick
    /// scroll delta without resetting the recognizer's translation.
    private var lastPanY: CGFloat = 0
    private var pan: UIPanGestureRecognizer!
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
        // SwiftTerm's tap/double/triple/long-press/pan recognizers are attached via
        // plain `addGestureRecognizer` calls with no public stored handle → disable
        // everything currently attached that is NOT ours. Ours aren't installed yet
        // at this point, so every existing recognizer here is SwiftTerm's (or a
        // sibling like pinch, which the mount installs AFTER this controller — order
        // matters, see mount).
        for gr in view.gestureRecognizers ?? [] where !ours.contains(gr) {
            gr.isEnabled = false
        }
    }

    private func installOurRecognizers(on view: TerminalView) {
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

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
        singleTap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        editMenu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(editMenu)

        ours = [pan, singleTap, doubleTap, tripleTap, longPress, twoFingerTap]
        for gr in ours { view.addGestureRecognizer(gr) }
    }

    func detach() {
        guard let view = terminalView else { return }
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
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        // Account for scrollback offset: the visible top row is contentOffset.y / cellH.
        let visualRow = Int((point.y + view.contentOffset.y) / cellH)
        let row = min(rows - 1, max(0, visualRow - Int(view.contentOffset.y / cellH)))
        return (col, row)
    }

    // MARK: Handlers

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }  // mouse app: SwiftTerm forwards
        // Cumulative translation since gesture start — GestureClassifier expects this
        // (it gates on a dead-zone radius from the origin). Never reset it, or the
        // classifier reclassifies each incremental tick as sub-dead-zone `.none`.
        let t = g.translation(in: view)
        switch g.state {
        case .began:
            lastPanY = 0
        case .changed:
            let decision = GestureClassifier.classify(
                dx: Double(t.x), dy: Double(t.y),
                isMultiWindowTmux: callbacks.isMultiWindowTmux())
            if case .scrollVertical = decision {
                // Apply only the delta since the last tick so scroll tracks the finger
                // live while the cumulative value keeps feeding the classifier.
                let dy = t.y - lastPanY
                var offset = view.contentOffset
                // Dragging down (finger moves down) reveals earlier scrollback → offset up.
                offset.y = max(0, offset.y - dy)
                view.setContentOffset(offset, animated: false)
            }
            lastPanY = t.y
        case .ended, .cancelled:
            // Decide window-switch from the full cumulative translation (one-per-drag).
            let decision = GestureClassifier.classify(
                dx: Double(t.x), dy: Double(t.y),
                isMultiWindowTmux: callbacks.isMultiWindowTmux())
            if case .switchWindow(let delta) = decision {
                callbacks.onSwitchWindow(delta)
            }
            lastPanY = 0
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }
        let p = g.location(in: view)
        let target = cell(at: p, in: view)
        callbacks.onPlaceCursor(target.col, target.row)
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        let p = g.location(in: view)
        let (col, row) = cell(at: p, in: view)
        // Word-select: expand from the tapped cell across non-space runs on that row.
        let (start, end) = wordBounds(col: col, row: row, in: view)
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        let p = g.location(in: view)
        let (_, row) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        view.setSelectionRange(start: Position(col: 0, row: row),
                               end: Position(col: cols - 1, row: row))
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        callbacks.onLongPressZoom()
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
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

extension TerminalGestureController: UIEditMenuInteractionDelegate {
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
