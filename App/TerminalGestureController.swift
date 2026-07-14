// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Owns the terminal touch map for a single `TerminalView`, replacing SwiftTerm's
/// built-in tap/long-press recognizers. In `.localScroll` a single-finger vertical
/// drag scrolls via the terminal's NATIVE `UIScrollView` pan (kept enabled — we do
/// not fight it); in `.appOwnsInput` (alt-screen) the mount parks that pan
/// (`isScrollEnabled = false`) and this controller streams the drag to the app as
/// arrow-key runs. A horizontal drag on the native pan switches tmux windows (one per
/// drag, on release, via `GestureClassifier` + the mount's clamp); single tap places
/// the cursor (in `.localScroll`; other modes yield the tap to the app);
/// double/triple-tap word/line-select; long-press zooms the tmux pane; two-finger
/// tap shows the edit menu. Routing is mode-driven: the mount tracks each pane's
/// `InteractionMode` (`.localScroll` / `.appOwnsInput` / `.mouseReporting`) and this
/// controller reads it via `currentMode()` — a `.mouseReporting` pane yields taps to
/// SwiftTerm's mouse forwarding (`allowMouseReporting = true`, set by the mount), while
/// an `.appOwnsInput` (alt-screen) pane keeps `allowMouseReporting = false` so SwiftTerm
/// does NOT consume the drag as mouse: its vertical drag is translated into arrow-key
/// runs streamed to the app instead of scrolling locally (its tap yields to the app).
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
        /// The pane's current `InteractionMode`: snapshotted once at drag `.began`,
        /// and read fresh on each tap. The single source of truth for gesture routing.
        let currentMode: () -> InteractionMode
        /// DECCKM (application-cursor-keys) state, snapshotted at drag `.began` so a
        /// single drag encodes consistently even if the app flips the mode mid-drag.
        let applicationCursorKeys: () -> Bool
        /// Sends raw bytes to the remote (arrow-key runs from an alt-screen drag).
        let sendBytes: ([UInt8]) -> Void
        let hasSelection: () -> Bool
        let clearSelection: () -> Void
    }

    private weak var terminalView: TerminalView?
    private let callbacks: Callbacks

    // Per-gesture snapshot state, taken once at drag `.began` so mode/DECCKM can't
    // change mid-drag and split one gesture across two interpretations.
    private var dragMode: InteractionMode = .localScroll
    private var dragAppCursor: Bool = false
    /// Running total of cells already turned into arrows this drag (fed back into
    /// `AltScreenScroll.arrows` so successive `.changed` samples send only the new delta).
    private var emittedCells: Int = 0

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

    /// Disable SwiftTerm's LAZILY-created selection/mouse pan recognizers.
    ///
    /// The init-time `disableSwiftTermRecognizers` sweep is a one-time snapshot, but
    /// SwiftTerm creates its `panSelectionGesture` (and `panMouseGesture`) on demand —
    /// `enableSelectionPanGesture()` runs the first time a selection becomes active, i.e.
    /// AFTER our sweep. That recognizer (an extra `UIPanGestureRecognizer` that is neither
    /// ours nor the inherited scroll pan) then hijacks every subsequent drag as a text
    /// selection (device trace 2026-07-13: sweep count flipped 12↔13 as it came and went,
    /// and drag-selections produced no `sel:` log because the driver was SwiftTerm's own
    /// recognizer, not our tap handlers). It's `internal`, so we can't call
    /// `disableSelectionPanGesture()`; instead we re-scan and disable any such stray pan
    /// at drag start. Cheap (a handful of recognizers) and idempotent.
    ///
    /// NOTE (build 42): this is now DEFENSE-IN-DEPTH, not the primary guard. It only runs
    /// on the scroll pan's `.began`, which never fires when the selection pan *wins*
    /// arbitration — that case is what let selection survive. The primary fix is the
    /// simultaneity delegate (`.selectionPan` mutually-exclusive with `.scrollPan` +
    /// `shouldRequireFailureOf` subordinating it), which makes the scroll pan win before
    /// the selection pan can start. This sweep stays as a cheap belt-and-suspenders.
    private func disableStraySwiftTermPans(on view: TerminalView) {
        var killed = 0
        for gr in view.gestureRecognizers ?? [] where
            gr is UIPanGestureRecognizer
            && gr !== view.panGestureRecognizer   // keep the scroll pan
            && !ours.contains(gr)                 // keep ours (none are pans anyway)
            && gr.isEnabled {
            gr.isEnabled = false
            killed += 1
        }
        if killed > 0 {
            DebugLog.shared.log(.gesture, "sweep2: disabled \(killed) stray SwiftTerm pan(s) (selection/mouse)")
        }
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
    /// target). The mode is snapshotted once at `.began` so a single drag can't
    /// straddle two interpretations mid-flight:
    /// - `.localScroll`: we do nothing — the scroll view itself owns the vertical
    ///   drag (native scroll, inertia, correct `isTracking`/scrollback).
    /// - `.appOwnsInput` (alt-screen): the mount has set `isScrollEnabled = false`,
    ///   so native scroll is inert; we translate the drag into arrow-key runs
    ///   (`AltScreenScroll`) streamed to the app on every `.changed`.
    /// - `.mouseReporting`: SwiftTerm forwards the drag as a mouse event; we no-op
    ///   entirely, including the window-switch classify on release.
    ///
    /// In ANY mode that lets us own the horizontal axis (i.e. not `.mouseReporting`),
    /// a horizontal-dominant drag in multi-window tmux still resolves a window switch
    /// once, on release, via `GestureClassifier` from the cumulative translation.
    @objc private func handleScrollViewPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            dragMode = callbacks.currentMode()
            dragAppCursor = callbacks.applicationCursorKeys()
            emittedCells = 0
            // Defense-in-depth (on top of the Kit simultaneity policy): the moment a
            // real drag starts, force-cancel any long-press by bouncing its `isEnabled`.
            // A long-press that recognized just before the pan was turning the held-then-
            // drag into a text selection (device trace 2026-07-13). This guarantees a
            // drag can never leave a live long-press behind, independent of recognizer
            // race ordering. It re-enables immediately so the next still-finger press
            // still zooms.
            if longPress.state == .began || longPress.state == .changed {
                longPress.isEnabled = false
                longPress.isEnabled = true
            }
            // Kill any lazily-created SwiftTerm selection/mouse pan before it can turn
            // this drag into a text selection (the one-time init sweep can't catch it).
            disableStraySwiftTermPans(on: view)
            DebugLog.shared.log(.gesture, "gr:scrollPan began mode=\(dragMode) appCursor=\(dragAppCursor)")
        case .changed:
            guard dragMode == .appOwnsInput else { return }
            let term = view.getTerminal()
            let cellH = view.bounds.height / CGFloat(max(term.rows, 1))
            let (runs, newEmitted) = AltScreenScroll.arrows(
                totalDy: Double(g.translation(in: view).y),
                cellHeight: Double(cellH),
                emittedCells: emittedCells)
            emittedCells = newEmitted
            for run in runs {
                let bytes = encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
                if !bytes.isEmpty { callbacks.sendBytes(bytes) }
            }
            if !runs.isEmpty {
                DebugLog.shared.log(.gesture, "gr:scrollPan altScreen runs=\(runs.count) emittedCells=\(emittedCells)")
            }
        case .ended, .cancelled:
            // Window-switch resolves once, from cumulative translation, in ANY mode
            // that lets us own the horizontal axis (not mouseReporting).
            guard dragMode != .mouseReporting else { return }
            let t = g.translation(in: view)
            let decision = GestureClassifier.classify(
                dx: Double(t.x), dy: Double(t.y),
                isMultiWindowTmux: callbacks.isMultiWindowTmux())
            if case .switchWindow(let delta) = decision {
                callbacks.onSwitchWindow(delta)
            }
        default: break
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        // A tap always raises the keyboard. We replaced SwiftTerm's own tap recognizer
        // (which called `becomeFirstResponder`), and PR #90's `editingInteractionConfiguration
        // = .none` suppressed the system tap-to-focus, so nothing re-presented the keyboard
        // after a dismiss (device report, build 44). Raise it explicitly here in EVERY mode
        // — even an alt-screen/mouse-reporting app needs the keyboard to type.
        if !view.isFirstResponder {
            let ok = view.becomeFirstResponder()
            DebugLog.shared.log(.gesture, "gesture:singleTap becomeFirstResponder=\(ok)")
        }
        switch callbacks.currentMode() {
        case .mouseReporting, .appOwnsInput:
            // App owns clicks. In `.mouseReporting` SwiftTerm forwards the tap as a mouse
            // event (`allowMouseReporting = true`). In `.appOwnsInput` we keep mouse
            // reporting OFF (so the drag reaches our arrow path), so the tap simply yields
            // — no cursor placement, no mouse. Either way, don't place a cursor here.
            DebugLog.shared.log(.gesture, "gesture:singleTap action=appOwns mode=\(callbacks.currentMode())")
            return
        case .localScroll:
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

    /// Map a recognizer to its pure `GestureRole` so the simultaneity policy is a
    /// Linux-tested decision (`gesturesMayRecognizeSimultaneously`). The scroll pan is
    /// the terminal view's inherited `UIScrollView.panGestureRecognizer`, NOT one of
    /// ours; identity-match it. `longPress` is ours; pinch is a `UIPinchGestureRecognizer`
    /// installed by the mount; everything else is a tap or unmodeled.
    private func role(of g: UIGestureRecognizer) -> GestureRole {
        if g === terminalView?.panGestureRecognizer { return .scrollPan }
        if g === longPress { return .longPress }
        if g is UIPinchGestureRecognizer { return .pinch }
        if g is UITapGestureRecognizer { return .tap }
        // A pan that is neither the inherited scroll pan nor one of ours (ours are all
        // taps + a long-press, never pans) is SwiftTerm's lazily-created
        // selection/mouse pan — the recognizer that hijacks a drag as text selection.
        // Classifying it as `.selectionPan` makes the simultaneity policy exclude it
        // from co-recognizing with the scroll pan.
        if g is UIPanGestureRecognizer { return .selectionPan }
        return .other
    }

    // Simultaneity policy lives in Kit (`gesturesMayRecognizeSimultaneously`): pinch
    // coexists with the 1-finger pan/taps, but the long-press must NOT co-recognize
    // with the scroll pan — otherwise a moving-finger drag was treated as a held-touch
    // text selection (device trace 2026-07-13: every drag started a selection). Making
    // that one pairing exclusive lets the pan cancel the long-press on movement.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return gesturesMayRecognizeSimultaneously(role(of: g), role(of: other))
    }

    /// Make SwiftTerm's selection/mouse pan *lose* to the native scroll pan.
    ///
    /// `shouldRecognizeSimultaneouslyWith == false` only stops the two pans from
    /// co-recognizing; it does not decide WHICH wins, so the selection pan could still
    /// beat the scroll pan and drive a text selection (build-42 device trace). Requiring
    /// the selection pan to fail until the scroll pan fails guarantees a plain vertical
    /// drag scrolls. Delivered to the selection pan (`g`), naming the scroll pan as the
    /// one it must wait on.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        return role(of: g) == .selectionPan && role(of: other) == .scrollPan
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
