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
/// arrow-key runs. A horizontal drag on the native pan is axis-locked via
/// `DragAxisLock`; no live rendering happens during the drag, and on release past
/// threshold `SwitchCommitDecision` fires the window switch. single tap places
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
        /// The resolved alt-screen scroll DECISION for THIS pane (inputs + keys + reason),
        /// snapshotted once at drag `.began` via the pure `altScrollDecision(...)` decider.
        /// The controller logs `decision.logLine` verbatim so the line reflects what the
        /// decider actually saw (not the caller's belief). `.keys` drives arrow-vs-page.
        let altScrollDecision: () -> AltScrollDecision
        /// Sends raw bytes to the remote (arrow-key runs from an alt-screen drag).
        let sendBytes: ([UInt8]) -> Void
        let hasSelection: () -> Bool
        let clearSelection: () -> Void
        /// Release PAST threshold on a switch-locked horizontal drag: commit the switch
        /// by `delta` (tmux select-window). The sole switch callback: the drag has no
        /// live-render phase, so a short release simply does nothing (no callback).
        let onDragCommit: (_ delta: Int) -> Void
    }

    private weak var terminalView: TerminalView?
    private let callbacks: Callbacks

    // Per-gesture snapshot state, taken once at drag `.began` so mode/DECCKM can't
    // change mid-drag and split one gesture across two interpretations.
    private var dragMode: InteractionMode = .localScroll
    private var dragAppCursor: Bool = false
    /// Key family for the in-flight alt-screen drag, snapshotted at `.began` so a single
    /// drag can't switch arrow↔page mid-flight.
    private var dragDecision: AltScrollDecision =
        AltScrollDecision(keys: .wheel, mode: .wheel, paneCommand: nil, reason: "wheel")
    /// Running total of cells already turned into arrows this drag (fed back into
    /// `AltScreenScroll.arrows` so successive `.changed` samples send only the new delta).
    private var emittedCells: Int = 0
    /// Axis this drag locked to (decided once past the dead-zone). `.pending` until then.
    private var dragAxis: DragAxis = .pending

    // MARK: Alt-screen scroll momentum (fling)
    /// Drives the post-release decaying wheel-event fling for alt-screen scroll (the native
    /// `UIScrollView` gives normal-shell scroll momentum for free; the synthetic emitter does
    /// not). Nil when no fling is in flight.
    private var flingDisplayLink: CADisplayLink?
    /// The active fling's decay model + start time + per-fling accounting, mirroring the
    /// drag's `emittedCells` so the tick loop emits only the NEW whole-cell delta each frame.
    private var flingMomentum: ScrollMomentum?
    private var flingStartTime: CFTimeInterval = 0
    private var flingEmittedCells: Int = 0
    /// The alt-screen key family + drag-point coordinate captured at release, so the fling
    /// emits the same key kind at a stable coordinate (the finger is gone).
    private var flingDecision: AltScrollDecision =
        AltScrollDecision(keys: .wheel, mode: .wheel, paneCommand: nil, reason: "wheel")
    private var flingAppCursor: Bool = false
    private var flingCoord: (col: Int, row: Int) = (1, 1)

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
    /// OUR alt-screen drag pan. Enabled ONLY while the pane is in `.appOwnsInput`
    /// (toggled by the mount via `setAltScreenPanEnabled` in the same mode-transition
    /// handler that flips `isScrollEnabled`). It exists because in `.appOwnsInput` the
    /// mount sets `isScrollEnabled = false`, which DISABLES the inherited
    /// `UIScrollView.panGestureRecognizer` — so our `handleScrollViewPan` target on that
    /// recognizer never fires there (device-proven, build 47: `gr:scrollPan began
    /// mode=appOwnsInput` = 0). This pan survives that flip because it is our own,
    /// independent recognizer. Gating it on the mode guarantees exactly ONE live
    /// drag-recognizer per mode (native pan in `.localScroll`, this one in
    /// `.appOwnsInput`) — no straddle.
    private var altScreenPan: UIPanGestureRecognizer!

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

    /// Durably subordinate SwiftTerm's LAZILY-created selection/mouse pan to the native
    /// scroll pan, at the moment it first exists. Unlike `disableStraySwiftTermPans` (a
    /// per-drag scan that misses the case where the selection pan WINS arbitration before
    /// our `.began` handler runs), this wires the pan into the failure tree ONCE: it sets
    /// our delegate (so the existing `shouldRequireFailureOf` selectionPan-vs-scrollPan
    /// rule fires) and calls `require(toFail:)` directly as redundant insurance. Idempotent
    /// (re-setting the same delegate / re-adding the same failure requirement is a no-op).
    private func subordinateSelectionPan(on view: TerminalView) {
        let scrollPan = view.panGestureRecognizer
        for gr in view.gestureRecognizers ?? [] where
            gr is UIPanGestureRecognizer
            && gr !== scrollPan            // not the scroll pan (our authoritative owner)
            && !ours.contains(gr) {        // not one of ours
            if gr.delegate !== self {
                gr.delegate = self
                gr.require(toFail: scrollPan)
                DebugLog.shared.log(.gesture,
                    "selectionPan subordinated (delegate+require-fail vs scrollPan)")
            }
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

        // OUR alt-screen drag pan. Starts DISABLED — the pane mounts in `.localScroll`
        // where the native scroll pan owns the drag. The mount enables it on transition
        // into `.appOwnsInput` (see `setAltScreenPanEnabled`), where `isScrollEnabled =
        // false` has parked the native pan and this is the only live drag-owner.
        altScreenPan = UIPanGestureRecognizer(target: self, action: #selector(handleAltScreenPan(_:)))
        altScreenPan.delegate = self
        altScreenPan.isEnabled = false

        ours = [singleTap, doubleTap, tripleTap, longPress, twoFingerTap, altScreenPan]
        for gr in ours { view.addGestureRecognizer(gr) }

        // Vertical scrolling stays NATIVE (the inherited UIScrollView pan, kept enabled
        // by the sweep) in `.localScroll`. We ride that same recognizer to detect a
        // horizontal drag = tmux window switch, so we never fight the scroll view with a
        // competing pan there. (In `.appOwnsInput` that recognizer is disabled by
        // `isScrollEnabled = false`; `altScreenPan` above takes over.)
        view.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))

        // Bug B diagnosis: observe every non-ours recognizer's state so a drag that
        // never reaches `handleScrollViewPan` still logs which recognizer won.
        observeStrayRecognizers(on: view)

        // Tap snappiness: UIScrollView delays content-touch delivery (~150ms) to first
        // decide whether a touch is the start of a scroll, which made single-tap cursor
        // placement feel sluggish. Deliver touches immediately — our tap recognizers no
        // longer wait on the scroll-detection window. (The pan still recognizes a drag
        // fine; only the initial delivery delay is removed.)
        view.delaysContentTouches = false
    }

    func detach() {
        stopAltScreenFling()   // kill any live display link so it can't retain self after detach
        guard let view = terminalView else { return }
        view.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollViewPan(_:)))
        for gr in ours { view.removeGestureRecognizer(gr) }
        view.removeInteraction(editMenu)
        ours = []
    }

    /// Enable OUR alt-screen drag pan (arrow-key synthesis) for exactly the
    /// `.appOwnsInput` mode, and disable it otherwise. Called by the mount from the
    /// `modeTracker.onChange` handler — the same place it flips `view.isScrollEnabled` —
    /// so the two toggles stay in lockstep: native scroll pan and our pan are never both
    /// live. `enabled == (mode == .appOwnsInput)` at the call site.
    func setAltScreenPanEnabled(_ enabled: Bool) {
        altScreenPan?.isEnabled = enabled
        DebugLog.shared.log(.gesture, "altPan enabled=\(enabled)")
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
        // `point` is `gesture.location(in: view)`, and `view` is a UIScrollView, so `point`
        // is in CONTENT space (includes the scroll offset). SwiftTerm's own `calculateTapHit`
        // and its selection / `getCharData` APIs want a VIEWPORT screen row (0..<rows); its
        // `getLine` adds `buffer.yDisp` itself. So convert content -> viewport by subtracting
        // `contentOffset.y`, and do NOT add `yDisp` (adding it double-counts: the old
        // "double/triple-tap selected a row far above the tap once scrolled" bug). Vertical
        // scroll does not affect `col`, so `point.x` is used directly above.
        let row = TapRowMapping.row(contentY: Double(point.y),
                                    contentOffsetY: Double(view.contentOffset.y),
                                    cellHeight: Double(cellH), rows: rows)
        return (col, row)
    }

    // MARK: Handlers

    @objc private func observeRecognizerState(_ g: UIGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        // A: catch a swipe that loses the recognizer race before `drag-begin` logs. Identify
        // which non-ours recognizer began/changed on the terminal view (SwiftTerm's scroll or
        // lazy selection pan). If this fires without a following `drag-begin`, that recognizer
        // pre-empted our switch drag (the invisible intermittent-swipe miss, device 2026-07-22).
        let kind: String
        if g === terminalView?.panGestureRecognizer { kind = "scrollPan" }
        else if g is UIPanGestureRecognizer { kind = "strayPan" }
        else { kind = String(describing: type(of: g)) }
        DebugLog.shared.log(.gesture,
            "gr-observe \(kind) state=\(g.state.rawValue) mode=\(callbacks.currentMode())")
    }

    /// Attach `observeRecognizerState` as an extra target on every recognizer on the
    /// view that is not one of ours, so any of them firing is logged. Idempotent per
    /// recognizer (UIKit ignores a duplicate identical target/action). Called when a
    /// pane enters `.appOwnsInput` (the only mode where the drag goes missing).
    private func observeStrayRecognizers(on view: TerminalView) {
        for gr in view.gestureRecognizers ?? [] where !ours.contains(gr) && gr !== view.panGestureRecognizer {
            gr.addTarget(self, action: #selector(observeRecognizerState(_:)))
        }
        // Also observe the inherited scroll pan itself, to confirm whether it (our
        // intended owner) begins or is pre-empted.
        view.panGestureRecognizer.addTarget(self, action: #selector(observeRecognizerState(_:)))
    }

    /// Snapshot mode + DECCKM once at a drag's `.began`, and clean up recognizers that
    /// could hijack the drag. Shared by both drag handlers so a single gesture can't
    /// straddle two interpretations mid-flight. Returns the snapshotted mode.
    @discardableResult
    private func beginDrag(_ owner: String, on view: TerminalView) -> InteractionMode {
        // A new touch always kills an in-flight momentum fling (catch-the-scroll), so the
        // finger takes over immediately rather than fighting the decaying stream.
        stopAltScreenFling()
        dragMode = callbacks.currentMode()
        dragAppCursor = callbacks.applicationCursorKeys()
        dragDecision = callbacks.altScrollDecision()
        emittedCells = 0
        dragAxis = .pending
        // Defense-in-depth (on top of the Kit simultaneity policy): the moment a real
        // drag starts, force-cancel any long-press by bouncing its `isEnabled`. A
        // long-press that recognized just before the pan was turning the held-then-drag
        // into a text selection (device trace 2026-07-13). This guarantees a drag can
        // never leave a live long-press behind, independent of recognizer race ordering.
        // It re-enables immediately so the next still-finger press still zooms.
        if longPress.state == .began || longPress.state == .changed {
            longPress.isEnabled = false
            longPress.isEnabled = true
        }
        // Primary fix: durably subordinate the selection pan the instant it exists.
        subordinateSelectionPan(on: view)
        // Kill any lazily-created SwiftTerm selection/mouse pan before it can turn this
        // drag into a text selection (the one-time init sweep can't catch it).
        disableStraySwiftTermPans(on: view)
        observeStrayRecognizers(on: view)   // A: observe stray recognizers in ALL modes (catch localScroll swipe-race misses)
        // `imode=` is the InteractionMode; `dragDecision.logLine` carries its own
        // `mode=` (the AltScrollMode). Distinct keys so the one line stays unambiguous
        // (the B retest reads `imode=` to tell mouseReporting from appOwnsInput).
        DebugLog.shared.log(.gesture,
            "drag-begin winner=\(owner) imode=\(dragMode) appCursor=\(dragAppCursor) \(dragDecision.logLine)")
        return dragMode
    }

    /// Feed the drag's cumulative translation through the axis lock. Returns true if this
    /// drag is (now) switch-locked (horizontal) so the caller suppresses its scroll/arrow
    /// path. No live rendering: the switch fires only on release (see `resolveLiveSwitch`).
    private func driveLiveSwitch(_ g: UIPanGestureRecognizer, in view: TerminalView) -> Bool {
        let t = g.translation(in: view)
        if case .pending = dragAxis {
            let multiWin = callbacks.isMultiWindowTmux()
            dragAxis = DragAxisLock.resolve(dx: Double(t.x), dy: Double(t.y),
                                            isMultiWindowTmux: multiWin)
            if case .pending = dragAxis {
                // still inside the dead-zone; no decision yet
            } else {
                let (axisDesc, reason): (String, String)
                switch dragAxis {
                case .switchWindow(let delta): axisDesc = "switchWindow(delta=\(delta))"; reason = "dominance"
                case .scroll: axisDesc = "scroll"; reason = "vertical-or-single"
                case .pending: axisDesc = "pending"; reason = "dead-zone"
                }
                DebugLog.shared.log(.gesture, decisionLine(
                    "drag-axis-lock",
                    inputs: [("dx", "\(Int(t.x))"), ("dy", "\(Int(t.y))"), ("multiWin", "\(multiWin)")],
                    outputs: [("axis", axisDesc)],
                    reason: reason))
            }
        }
        if case .switchWindow = dragAxis { return true }
        return false
    }

    /// On release, resolve commit-vs-nothing for a switch-locked drag. Returns true if this
    /// was a switch drag (caller skips its own resolution). Commit fires `onDragCommit`
    /// (-> tmux select-window); a short drag does nothing (no animation to cancel).
    private func resolveLiveSwitch(_ g: UIPanGestureRecognizer, in view: TerminalView) -> Bool {
        guard case .switchWindow = dragAxis else { return false }
        let t = g.translation(in: view)
        let v = g.velocity(in: view)
        let width = Double(view.bounds.width)
        switch SwitchCommitDecision.resolve(dx: Double(t.x), width: width, velocity: Double(v.x)) {
        case .commit(let delta):
            DebugLog.shared.log(.gesture, "drag-switch commit delta=\(delta) dx=\(Int(t.x)) vx=\(Int(v.x))")
            callbacks.onDragCommit(delta)
        case .springBack:
            DebugLog.shared.log(.gesture, "drag-switch short dx=\(Int(t.x)) vx=\(Int(v.x)) - no switch")
        }
        return true
    }

    /// Rides the terminal's NATIVE UIScrollView pan (we added ourselves as an extra
    /// target). This recognizer is only LIVE in `.localScroll` (in `.appOwnsInput` the
    /// mount sets `isScrollEnabled = false`, which disables it — `altScreenPan` owns the
    /// drag there instead; in `.mouseReporting` SwiftTerm forwards the drag as a mouse
    /// event). So here the scroll view itself owns the vertical drag (native scroll,
    /// inertia, correct `isTracking`/scrollback) and we only resolve a horizontal-drag
    /// tmux window-switch, once, on release.
    @objc private func handleScrollViewPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            beginDrag("scrollPan", on: view)
        case .changed:
            // Give the horizontal drag first refusal at the switch axis; if it locks to
            // switch, the native scroll is suppressed for this drag (we drive the transform).
            _ = driveLiveSwitch(g, in: view)
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }   // switch drag handled
            DebugLog.shared.log(.gesture,
                "drag-end owner=scrollPan imode=\(dragMode) outcome=\(dragMode == .localScroll ? "scroll" : "none")")
        default: break
        }
    }

    /// OUR alt-screen drag pan — enabled ONLY in `.appOwnsInput` (via
    /// `setAltScreenPanEnabled`). The mount has parked the native scroll pan
    /// (`isScrollEnabled = false`) there, so this is the single live drag-owner: it
    /// translates the vertical drag into arrow-key runs (`AltScreenScroll`) streamed to
    /// the app on every `.changed` (xterm Alternate-Scroll model), and resolves a
    /// horizontal-drag tmux window-switch once on release.
    @objc private func handleAltScreenPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            beginDrag("altPan", on: view)
        case .changed:
            if driveLiveSwitch(g, in: view) { return }   // horizontal switch owns this drag
            // The pan is only enabled in `.appOwnsInput`, but re-check the snapshot so a
            // mid-mount edge (enabled just as the mode left) can't emit stray arrows.
            guard dragMode == .appOwnsInput else { return }
            let term = view.getTerminal()
            let cols = max(term.cols, 1), rows = max(term.rows, 1)
            let cellH = view.bounds.height / CGFloat(rows)
            let cellW = view.bounds.width / CGFloat(max(cols, 1))
            let loc = g.location(in: view)
            // 1-based cell coordinate of the drag point, clamped to the pane (SGR coords are 1-based).
            let col = min(max(1, Int(loc.x / max(cellW, 1)) + 1), cols)
            let row = min(max(1, Int(loc.y / max(cellH, 1)) + 1), rows)
            let dy = Double(g.translation(in: view).y)
            var sent = 0
            switch dragDecision.keys {
            case .wheel:
                let (runs, newEmitted) = AltScreenScroll.wheelEvents(
                    totalDy: dy, cellHeight: Double(cellH), emittedCells: emittedCells)
                emittedCells = newEmitted
                for run in runs {
                    let bytes = encodeWheelRun(run, col: col, row: row)
                    if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
                }
                if !runs.isEmpty {
                    DebugLog.shared.log(.gesture,
                        "drag-move keys=wheel runs=\(runs.count) sent=\(sent) total=\(emittedCells) coord=(\(col),\(row))")
                }
            case .arrows, .pageKeys:
                let (runs, newEmitted) = AltScreenScroll.arrows(
                    totalDy: dy, cellHeight: Double(cellH), emittedCells: emittedCells)
                emittedCells = newEmitted
                for run in runs {
                    let bytes = dragDecision.keys == .pageKeys
                        ? encodePageKeyRun(run)
                        : encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
                    if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
                }
                if !runs.isEmpty {
                    DebugLog.shared.log(.gesture,
                        "drag-move keys=\(dragDecision.keys) runs=\(runs.count) sent=\(sent) total=\(emittedCells)")
                }
            }
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }  // switch drag handled
            let outcome: String
            if emittedCells != 0 {
                switch dragDecision.keys {
                case .wheel:    outcome = "wheel"
                case .pageKeys: outcome = "pageKeys"
                case .arrows:   outcome = "arrows"
                }
            } else {
                outcome = "none"
            }
            DebugLog.shared.log(.gesture,
                "drag-end owner=altPan imode=\(dragMode) emitted=\(emittedCells) outcome=\(outcome)")
            // Fling: on a real scroll release (not a switch, not cancelled), carry the drag's
            // velocity into a decaying post-release wheel-event stream so alt-screen scroll has
            // the same momentum the native shell scroll gets for free.
            if g.state == .ended, dragMode == .appOwnsInput, emittedCells != 0 {
                startAltScreenFling(releaseVelocityY: Double(g.velocity(in: view).y), in: view)
            }
        default: break
        }
    }

    // MARK: Alt-screen scroll momentum (fling)

    /// Start a decaying post-release wheel-event fling from `releaseVelocityY` (points/sec, as
    /// UIKit reports pan velocity: +down / −up). Below `minFlingVelocity` this is a no-op (a
    /// slow lift just stops). Captures the alt-screen key family + a stable drag-point
    /// coordinate at release (the finger is gone during the fling), then drives a `CADisplayLink`
    /// that emits the same wheel events the live drag would, decelerating to a stop.
    private func startAltScreenFling(releaseVelocityY: Double, in view: TerminalView) {
        stopAltScreenFling()   // never stack two flings
        let momentum = ScrollMomentum(velocity: releaseVelocityY)
        guard !momentum.isFinished(at: 0) else { return }   // too slow to fling
        // Stable coordinate for the fling's SGR wheel encoding: the last drag point.
        let term = view.getTerminal()
        let cols = max(term.cols, 1), rows = max(term.rows, 1)
        let cellH = view.bounds.height / CGFloat(rows), cellW = view.bounds.width / CGFloat(cols)
        let loc = view.panGestureRecognizer.location(in: view)
        flingCoord = (min(max(1, Int(loc.x / max(cellW, 1)) + 1), cols),
                      min(max(1, Int(loc.y / max(cellH, 1)) + 1), rows))
        flingMomentum = momentum
        flingDecision = dragDecision
        flingAppCursor = dragAppCursor
        flingEmittedCells = 0
        let link = CADisplayLink(target: self, selector: #selector(tickAltScreenFling(_:)))
        link.add(to: .main, forMode: .common)
        flingDisplayLink = link
        flingStartTime = CACurrentMediaTime()
        DebugLog.shared.log(.gesture,
            "fling start v=\(Int(releaseVelocityY)) keys=\(dragDecision.keys) coord=\(flingCoord)")
    }

    /// Cancel any in-flight fling (new touch, detach). Idempotent.
    private func stopAltScreenFling() {
        guard flingDisplayLink != nil else { return }
        flingDisplayLink?.invalidate()
        flingDisplayLink = nil
        flingMomentum = nil
        DebugLog.shared.log(.gesture, "fling stop total=\(flingEmittedCells)")
    }

    /// One fling frame: advance the decay model, convert the NEW cumulative offset into wheel
    /// events (same `AltScreenScroll` accounting as the live drag, using the fling's own
    /// `flingEmittedCells`), emit them, and stop once the model has decayed below threshold.
    @objc private func tickAltScreenFling(_ link: CADisplayLink) {
        guard let view = terminalView, let momentum = flingMomentum else { stopAltScreenFling(); return }
        let t = CACurrentMediaTime() - flingStartTime
        let rows = max(view.getTerminal().rows, 1)
        let cellH = view.bounds.height / CGFloat(rows)
        let totalDy = momentum.offset(at: t)
        var sent = 0
        switch flingDecision.keys {
        case .wheel:
            let (runs, newEmitted) = AltScreenScroll.wheelEvents(
                totalDy: totalDy, cellHeight: Double(cellH), emittedCells: flingEmittedCells)
            flingEmittedCells = newEmitted
            for run in runs {
                let bytes = encodeWheelRun(run, col: flingCoord.col, row: flingCoord.row)
                if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
            }
        case .arrows, .pageKeys:
            let (runs, newEmitted) = AltScreenScroll.arrows(
                totalDy: totalDy, cellHeight: Double(cellH), emittedCells: flingEmittedCells)
            flingEmittedCells = newEmitted
            for run in runs {
                let bytes = flingDecision.keys == .pageKeys
                    ? encodePageKeyRun(run)
                    : encodeArrowRun(run, applicationCursorKeys: flingAppCursor)
                if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
            }
        }
        if sent > 0 {
            DebugLog.shared.log(.gesture, "fling tick t=\(String(format: "%.2f", t)) sent=\(sent) total=\(flingEmittedCells)")
        }
        if momentum.isFinished(at: t) { stopAltScreenFling() }
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
        // Word-select only makes sense on the NORMAL screen (`.localScroll`). On an
        // app-owned screen (`.appOwnsInput` = Claude/vim/htop, or `.mouseReporting`) the app
        // draws the alternate screen, so a LOCAL SwiftTerm selection keyed on `term.rows`
        // does not correspond to what is rendered (device build 55: a double-tap selected a
        // garbage bottom row regardless of tap position). Yield, exactly like single-tap.
        guard callbacks.currentMode() == .localScroll else {
            DebugLog.shared.log(.gesture, "gr:doubleTap yield mode=\(callbacks.currentMode())")
            return
        }
        let p = g.location(in: view)
        let (col, row) = cell(at: p, in: view)
        // Word-select: expand from the tapped cell across non-space runs on that row.
        let (start, end) = wordBounds(col: col, row: row, in: view)
        DebugLog.shared.log(.gesture, "sel:before hasActive=\(view.hasActiveSelection)")
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        subordinateSelectionPan(on: view)   // the selection pan is created now; subordinate it at birth
        DebugLog.shared.log(.gesture, "sel:after set (\(start),\(row))-(\(end),\(row)) hasActive=\(view.hasActiveSelection)")
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        // Line-select only makes sense on the NORMAL screen (see `handleDoubleTap`): yield on
        // an app-owned screen where a local selection does not match the app's render.
        guard callbacks.currentMode() == .localScroll else {
            DebugLog.shared.log(.gesture, "gr:tripleTap yield mode=\(callbacks.currentMode())")
            return
        }
        let p = g.location(in: view)
        let (_, row) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        DebugLog.shared.log(.gesture, "sel:before hasActive=\(view.hasActiveSelection)")
        view.setSelectionRange(start: Position(col: 0, row: row),
                               end: Position(col: cols - 1, row: row))
        subordinateSelectionPan(on: view)   // the selection pan is created now; subordinate it at birth
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
        if g === altScreenPan { return .altScreenPan }
        if g === longPress { return .longPress }
        if g is UIPinchGestureRecognizer { return .pinch }
        if g is UITapGestureRecognizer { return .tap }
        // A pan that is neither the inherited scroll pan, our alt-screen pan, nor one of
        // our taps/long-press is SwiftTerm's lazily-created selection/mouse pan — the
        // recognizer that hijacks a drag as text selection. Classifying it as
        // `.selectionPan` makes the simultaneity policy exclude it from co-recognizing
        // with the scroll pan.
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
