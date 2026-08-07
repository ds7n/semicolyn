// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Owns the terminal touch map for a single `TerminalView`, replacing SwiftTerm's
/// built-in tap/long-press recognizers. In `.localScroll` a single-finger vertical
/// drag scrolls via the terminal's NATIVE `UIScrollView` pan (kept enabled, we do
/// not fight it); in `.appOwnsInput` (alt-screen) the mount parks that pan
/// (`isScrollEnabled = false`) and this controller streams the drag to the app as
/// arrow-key runs. A horizontal drag on the native pan is axis-locked via
/// `DragAxisLock`; no live rendering happens during the drag, and on release past
/// threshold `SwitchCommitDecision` fires the window switch. single tap places
/// the cursor (in `.localScroll`; other modes yield the tap to the app);
/// double/triple-tap word/line-select; long-press zooms the tmux pane; two-finger
/// tap shows the edit menu. Routing is mode-driven: the mount tracks each pane's
/// `InteractionMode` (`.localScroll` / `.appOwnsInput` / `.mouseReporting`) and this
/// controller reads it via `currentMode()`, a `.mouseReporting` pane yields taps to
/// SwiftTerm's mouse forwarding (`allowMouseReporting = true`, set by the mount), while
/// an `.appOwnsInput` (alt-screen) pane keeps `allowMouseReporting = false` so SwiftTerm
/// does NOT consume the drag as mouse: its vertical drag is translated into arrow-key
/// runs streamed to the app instead of scrolling locally (its tap yields to the app).
///
/// SwiftTerm's own tap/long-press/pan recognizers are added via plain
/// `addGestureRecognizer` calls but never stored behind a public accessor (its
/// `disableMousePanGesture()` / `disableSelectionPanGesture()` helpers are
/// `internal`, not `public`, in the pinned SwiftTerm release, not reachable from
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
        /// Whether THIS pane is currently the active (focused) pane. Read fresh
        /// on each tap; backs the tap-to-focus decision.
        let isActivePane: () -> Bool
        /// Focus THIS pane (tap on an inactive pane). Optimistically moves the
        /// accent border locally, then sends `select-pane -t %N`.
        let onSelectPane: () -> Void
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
    // tell ours apart from SwiftTerm's). Note: vertical scroll is NOT one of ours, it
    // stays on the terminal's native UIScrollView pan; the horizontal window-switch is
    // driven by our own `switchPan` (see `handleSwitchPan`), not by riding that pan.
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
    /// `UIScrollView.panGestureRecognizer` (device-proven, build 47: `gr:scrollPan began
    /// mode=appOwnsInput` = 0), and would also disable a `switchPan` riding it (the reason
    /// `switchPan` is instead our own independent recognizer, never attached to the
    /// inherited pan). This pan survives that flip because it is our own,
    /// independent recognizer. Gating it on the mode guarantees exactly ONE live
    /// drag-recognizer per mode (native pan in `.localScroll`, this one in
    /// `.appOwnsInput`), no straddle.
    private var altScreenPan: UIPanGestureRecognizer!
    /// OUR always-on window-switch pan. Unlike `altScreenPan` (only `.appOwnsInput`), this is
    /// enabled in `.localScroll`/`.mouseReporting` where the plain-shell swipe used to ride
    /// SwiftTerm's native scroll pan, which does NOT track a horizontal drag on a freshly
    /// created pane (contentSize 0). Owning the recognizer removes that dependency: the swipe
    /// fires regardless of scroll-view state. Axis-gated (DragAxisLock) so it acts only on a
    /// horizontal-dominant drag; the native scroll pan keeps handling vertical scroll.
    private var switchPan: UIPanGestureRecognizer!
    /// OUR selection-handle drag pan: grabs a selection endpoint circle (drawn by
    /// SwiftTerm's own `drawRect` once a selection is active) and drags it to grow/shrink
    /// the selection, the opposite end staying anchored. Like `selectionPan`/`switchPan`,
    /// it must never co-recognize with the native scroll pan or the always-on switch pan,
    /// or a handle-grab would instead scroll the view / start a window switch.
    private var handlePan: UIPanGestureRecognizer!

    /// The selection end currently being dragged by `handlePan`, set at `.began` and
    /// cleared at `.ended`/`.cancelled`.
    private var draggingEnd: SelectionEnd?
    /// The OTHER end of the selection, fixed for the duration of a handle drag (the
    /// anchor the moving end is measured against).
    private var anchoredEnd: (col: Int, row: Int)?
    /// The selection's current start/end grid positions, tracked by the controller because
    /// SwiftTerm's `selection` service is `internal` (the App can't read `selection.start/
    /// .end` directly). Set at EVERY `setSelectionRange` call site (double/triple-tap, the
    /// handle-pan handler) and cleared wherever the selection is cleared, so the controller
    /// stays the single source of truth for endpoint cell rects.
    private var storedStart: (col: Int, row: Int)?
    private var storedEnd: (col: Int, row: Int)?

    /// The floating magnifier shown while `handlePan` is dragging a selection handle
    /// (see `handleHandlePan`'s `.changed`/`.ended` branches); tracks the finger and
    /// hides on release.
    private lazy var loupe: SelectionLoupeView? = SelectionLoupeView()

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
        // which the mount installs AFTER this controller, order matters, see mount).
        //
        // CRUCIAL EXCEPTION: `TerminalView` is a `UIScrollView` and scrolls via its
        // INHERITED `panGestureRecognizer`. We must NOT disable it: doing so kills
        // native scrolling AND leaves `isTracking` false, so SwiftTerm's
        // `syncYDispFromContentOffset` (gated on `isTracking`) never updates scrollback.
        // We keep native scroll enabled; the window-switch decision is driven by our own
        // `switchPan` recognizer instead (see `handleSwitchPan`).
        //
        // EQUALLY CRUCIAL (device build 116, 2026-08-07): keeping ONLY `panGestureRecognizer`
        // is not enough. `UIScrollView` drives scrolling through a *cluster* of internal
        // recognizers, not the pan alone, chiefly `UIScrollViewDelayedTouchesBeganGesture-
        // Recognizer`, which promotes a settled touch into scroll tracking. Disabling it
        // left `nativePan` enabled but STUCK at `.possible` (state 0): every swipe logged a
        // `touch:begin` yet ZERO `scroll-trace`, the pan never `.began`, nothing scrolled.
        // So preserve every recognizer the scroll view owns (class prefixed `UIScrollView`),
        // not just the pan. These are SwiftTerm-external UIKit machinery; ours and
        // SwiftTerm's own tap/selection recognizers do not carry that prefix.
        for gr in view.gestureRecognizers ?? []
        where !ours.contains(gr) && gr !== view.panGestureRecognizer && !Self.isScrollViewInternal(gr) {
            gr.isEnabled = false
        }
        DebugLog.shared.log(.gesture, "sweep: disabled \(view.gestureRecognizers?.filter { !$0.isEnabled }.count ?? 0) recognizers; nativePan kept=\(view.panGestureRecognizer.isEnabled)")
    }

    /// True when `gr` is one of `UIScrollView`'s own internal support recognizers
    /// (class name prefixed `UIScrollView`, e.g. `UIScrollViewDelayedTouchesBegan-
    /// GestureRecognizer`, `UIScrollViewKnobLongPressGestureRecognizer`). The scroll
    /// view needs the whole cluster, not just `panGestureRecognizer`, to route a drag
    /// into scroll tracking, so the sweep must leave every one of them enabled. Matched
    /// by class-name prefix because these types are private (no public symbol to compare).
    static func isScrollViewInternal(_ gr: UIGestureRecognizer) -> Bool {
        String(describing: type(of: gr)).hasPrefix("UIScrollView")
    }

    /// Disable SwiftTerm's LAZILY-created selection/mouse pan recognizers.
    ///
    /// The init-time `disableSwiftTermRecognizers` sweep is a one-time snapshot, but
    /// SwiftTerm creates its `panSelectionGesture` (and `panMouseGesture`) on demand,
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
    /// arbitration, that case is what let selection survive. The primary fix is the
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
                if let switchPan {
                    gr.require(toFail: switchPan)
                }
                DebugLog.shared.log(.gesture,
                    "selectionPan subordinated (delegate+require-fail vs scrollPan+switchPan)")
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
        // single-tap deliberately requires ONLY double (not triple), so cursor
        // placement resolves after a single failed-double window, not the full
        // single→double→triple chain. Keeps all three gestures.
        singleTap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        editMenu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(editMenu)

        // OUR alt-screen drag pan. Starts DISABLED, the pane mounts in `.localScroll`
        // where the native scroll pan owns the drag. The mount enables it on transition
        // into `.appOwnsInput` (see `setAltScreenPanEnabled`), where `isScrollEnabled =
        // false` has parked the native pan and this is the only live drag-owner.
        altScreenPan = UIPanGestureRecognizer(target: self, action: #selector(handleAltScreenPan(_:)))
        altScreenPan.delegate = self
        altScreenPan.isEnabled = false

        switchPan = UIPanGestureRecognizer(target: self, action: #selector(handleSwitchPan(_:)))
        switchPan.delegate = self
        // Enabled at install (NOT via modeTracker.onChange, which fires only on a mode CHANGE
        // and so never fires for a fresh pane that starts in .localScroll: the exact bug).
        // The mount then toggles it on mode transitions via `setSwitchPanEnabled`.
        switchPan.isEnabled = true

        // OUR selection-handle drag pan. Always enabled (like the taps): `.began` hit-tests
        // the handle circles and CANCELS immediately when the touch isn't on one (see
        // `handleHandlePan`), so a plain content drag is unaffected and falls through to
        // whichever of `scrollPan`/`switchPan` would otherwise have won. Mutual exclusion
        // with both is the MIRROR IMAGE of how `subordinateSelectionPan` subordinates
        // SwiftTerm's own (unwanted) selection pan: there the scroll pan must win, so the
        // selection pan is required to fail first; here `handlePan` is the one we WANT to
        // win when a handle is grabbed, so `scrollPan`/`switchPan` are required to fail
        // against IT instead (see `gestureRecognizer(_:shouldRequireFailureOf:)` below).
        // `shouldRecognizeSimultaneouslyWith` also excludes the pairing so they never
        // co-recognize (same non-simultaneity guarantee `.selectionPan` gets from the Kit
        // policy, applied here directly since `handlePan` has no Kit `GestureRole` case,
        // deviation noted in the task report).
        handlePan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
        handlePan.delegate = self
        handlePan.isEnabled = true

        ours = [singleTap, doubleTap, tripleTap, longPress, twoFingerTap, altScreenPan, switchPan, handlePan]
        for gr in ours { view.addGestureRecognizer(gr) }

        // Bug B diagnosis: observe every non-ours recognizer's state so a drag that
        // never reaches `handleSwitchPan` still logs which recognizer won.
        observeStrayRecognizers(on: view)

        // Issue 3 scroll diagnosis: also observe the native scroll pan's FULL state
        // machine (observeStrayRecognizers' observer only fires on began/changed). This
        // lets a device swipe reveal a pan that .failed/.cancelled without ever beginning.
        view.panGestureRecognizer.addTarget(self, action: #selector(observeScrollPanAllStates(_:)))

        // Tap snappiness: UIScrollView delays content-touch delivery (~150ms) to first
        // decide whether a touch is the start of a scroll, which made single-tap cursor
        // placement feel sluggish. Deliver touches immediately, our tap recognizers no
        // longer wait on the scroll-detection window. (The pan still recognizes a drag
        // fine; only the initial delivery delay is removed.)
        view.delaysContentTouches = false
    }

    func detach() {
        stopAltScreenFling()   // kill any live display link so it can't retain self after detach
        guard let view = terminalView else { return }
        for gr in ours { view.removeGestureRecognizer(gr) }
        view.removeInteraction(editMenu)
        ours = []
        // The loupe was added to the persistent ContainerView (terminal.superview) on first
        // show(); hiding alone leaves an orphaned hidden subview behind on pane teardown, and
        // each per-pane controller owns its own loupe, so window switches would accumulate them.
        loupe?.removeFromSuperview()
        loupe = nil
    }

    /// Enable OUR alt-screen drag pan (arrow-key synthesis) for exactly the
    /// `.appOwnsInput` mode, and disable it otherwise. Called by the mount from the
    /// `modeTracker.onChange` handler, the same place it flips `view.isScrollEnabled`,
    /// so the two toggles stay in lockstep: native scroll pan and our pan are never both
    /// live. `enabled == (mode == .appOwnsInput)` at the call site.
    func setAltScreenPanEnabled(_ enabled: Bool) {
        altScreenPan?.isEnabled = enabled
        DebugLog.shared.log(.gesture, "altPan enabled=\(enabled)")
    }

    /// Enable OUR switch pan for `.localScroll`/`.mouseReporting` and disable it in
    /// `.appOwnsInput` (there `altScreenPan` owns the switch, exactly one switch-owner per
    /// mode). Called by the mount from `modeTracker.onChange`, alongside `setAltScreenPan`.
    func setSwitchPanEnabled(_ enabled: Bool) {
        switchPan?.isEnabled = enabled
        DebugLog.shared.log(.gesture, "switchPan enabled=\(enabled)")
    }

    // MARK: Cell geometry

    /// Convert a point in the terminal view to a cell using the terminal's current grid
    /// and the view's content size (SwiftTerm lays cells out uniformly). Returns BOTH a
    /// viewport row and an absolute (content/buffer) row, see below.
    private func cell(at point: CGPoint, in view: TerminalView) -> (col: Int, viewportRow: Int, absoluteRow: Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        let rows = max(term.rows, 1)
        // SwiftTerm derives rows = floor(bounds.height / trueCellHeight), so
        // bounds.height / rows OVERESTIMATES the true cell height by the fractional
        // leftover row; that overestimate makes taps land 1-2 rows too high. `caretFrame`
        // is the caret view's frame, exactly one true cell, so prefer it; it reads .zero
        // before the caret view exists, so fall back to the bounds/count formula then.
        let caret = view.caretFrame
        let cellW = caret.width  > 0 ? caret.width  : view.bounds.width  / CGFloat(cols)
        let cellH = caret.height > 0 ? caret.height : view.bounds.height / CGFloat(rows)
        guard cellW > 0, cellH > 0 else { return (0, 0, 0) }
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        // `point` is content-space (the view is a UIScrollView). Two row spaces are needed:
        //  - absoluteRow (content/buffer row) for setSelectionRange: the highlight draw loop
        //    and the copy path index buffer.lines[row] ABSOLUTELY, so a viewport row never
        //    matches once scrolled/alt-screen (yDisp>0) => the invisible-highlight bug.
        //  - viewportRow (0..<rows) for getCharData/getLine (SwiftTerm adds yDisp itself).
        // viewportRow is derived from absoluteRow, NOT from `view.contentOffset.y`: the
        // scroll-view's contentOffset drifts from the terminal's true `buffer.yDisp` by a
        // few rows (inset/scroll-timing), so `TapRowMapping.row` (contentOffset-based) picks
        // a viewport row that, once getCharData/getLine re-add the REAL yDisp, resolves to a
        // DIFFERENT absolute line than the one the highlight draws from `absoluteRow`. That
        // mismatch fed the word-boundary scanner wrong characters, landing sub-word
        // boundaries right at the tap column (1-char/partial-word selections). Subtracting
        // the terminal's own `getTopVisibleRow()` (== buffer.yDisp exactly) from absoluteRow
        // guarantees `absoluteRow - yDisp + yDisp == absoluteRow`, so getCharData/getLine
        // read the SAME line setSelectionRange/the highlight use.
        let totalRows = max(Int(view.contentSize.height / cellH), rows)
        let absoluteRow = TapRowMapping.absoluteRow(contentY: Double(point.y),
                                                    cellHeight: Double(cellH),
                                                    totalRows: totalRows)
        let yDisp = term.getTopVisibleRow()
        let viewportRow = max(0, min(rows - 1, absoluteRow - yDisp))
        return (col, viewportRow, absoluteRow)
    }

    /// A cell's on-screen rect in CONTENT space (matches `cell(at:in:)`'s coordinate
    /// space: `point` there is already content-space, so this is its inverse). `row` is
    /// the ABSOLUTE content/buffer row, the same space `setSelectionRange`/`storedStart`/
    /// `storedEnd` use (not the viewport row), so a handle rect stays correctly positioned
    /// once scrolled/alt-screen (yDisp > 0).
    private func cellRect(col: Int, row: Int, cellW: CGFloat, cellH: CGFloat, in view: TerminalView) -> CGRect {
        CGRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
    }

    /// The selection's current start/end grid positions, or nil when no selection is
    /// tracked. Backed by `storedStart`/`storedEnd` (see their declaration for why: SwiftTerm's
    /// `selection` service is `internal`, unreadable from the App).
    private func currentSelectionEnds(in view: TerminalView) -> (start: (col: Int, row: Int), end: (col: Int, row: Int))? {
        guard let s = storedStart, let e = storedEnd else { return nil }
        return (s, e)
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

    /// Issue 3 scroll diagnosis (device 2026-08-06): the native scroll pan never begins on
    /// a swipe (zero gr-observe, nothing scrolls) despite scroll range + an enabled pan.
    /// `observeRecognizerState` only logs `.began`/`.changed`, so a pan that reaches
    /// `.failed`/`.cancelled` WITHOUT ever beginning is invisible. This logs EVERY state
    /// transition of the native scroll pan (incl. .possible/.failed/.cancelled) with the
    /// translation + touch count, so a device swipe shows whether the pan begins, fails, or
    /// stays possible. Diagnostic only: attached as an extra target, changes no behavior.
    @objc private func observeScrollPanAllStates(_ g: UIGestureRecognizer) {
        guard let view = terminalView else { return }
        let t = (g as? UIPanGestureRecognizer)?.translation(in: view) ?? .zero
        DebugLog.shared.log(.gesture,
            "scroll-trace pan=nativePan state=\(g.state.rawValue) mode=\(callbacks.currentMode()) "
            + "touches=\(g.numberOfTouches) tx=\(Int(t.x)) ty=\(Int(t.y))")
    }

    /// Attach `observeRecognizerState` as an extra target on every recognizer on the
    /// view that is not one of ours, so any of them firing is logged. Idempotent per
    /// recognizer (UIKit ignores a duplicate identical target/action). Called on every
    /// drag start in ALL interaction modes, to catch a stray recognizer (SwiftTerm's
    /// scroll/selection pan) pre-empting our drag (the intermittent swipe-race miss).
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

    /// OUR switch pan handler (`.localScroll`/`.mouseReporting`). Axis-gated: on a
    /// horizontal-dominant drag it drives the window switch (via `driveLiveSwitch` /
    /// `resolveLiveSwitch`); on a vertical/pending drag it does nothing (the native scroll
    /// pan, co-recognizing, handles the scroll). Unlike the old ride-the-scroll-pan target,
    /// this fires regardless of scroll-view content/state.
    @objc private func handleSwitchPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            beginDrag("switchPan", on: view)
        case .changed:
            _ = driveLiveSwitch(g, in: view)   // horizontal -> switch; else no-op (scroll pan scrolls)
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }   // switch committed/spring-back
            DebugLog.shared.log(.gesture, "drag-end owner=switchPan imode=\(dragMode) outcome=none")
        default: break
        }
    }

    /// OUR alt-screen drag pan, enabled ONLY in `.appOwnsInput` (via
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

    /// OUR selection-handle drag pan. `.began` hit-tests the two endpoint handle circles
    /// (via `SemicolynKit.hitTestHandle`, generous `slop` since a fingertip is much
    /// bigger than the handle glyph) and immediately CANCELS if the touch isn't on
    /// either, so a plain content drag is unaffected (falls through to `scrollPan`/
    /// `switchPan`, which were made to wait on this recognizer's failure, see
    /// `gestureRecognizer(_:shouldRequireFailureOf:)`). `.changed` re-sets the selection
    /// with the anchored end fixed and the dragged end following the finger's cell
    /// (absolute row), normalized via `SemicolynKit.orderedSelection` so the selection
    /// never inverts mid-drag. `.ended` presents the edit menu (Copy/Paste), matching
    /// the double/triple-tap handlers.
    @objc private func handleHandlePan(_ g: UIPanGestureRecognizer) {
        // Deviation from the brief's snippet (a bare `return` here): `scrollPan`/`switchPan`
        // are required to fail against this recognizer (see `shouldRequireFailureOf`), so a
        // bare `return` on `.began` would leave this recognizer stuck in `.began` (UIKit has
        // already transitioned its state before invoking the target/action) with nothing to
        // release the pans waiting on it, PERMANENTLY blocking scroll/switch on any pane
        // with no active selection. Force-cancel via the isEnabled bounce (same proven idiom
        // `beginDrag` uses on `longPress`, see its comment above): writing `g.state =
        // .cancelled` directly on a stock, non-subclassed UIPanGestureRecognizer is not
        // reliably honored by UIKit's arbitration engine and may not release a recognizer
        // that `shouldRequireFailureOf` this one, whereas disabling/re-enabling forces a real
        // failure UIKit's dependency graph does honor.
        guard let view = terminalView, view.hasActiveSelection else {
            if g.state == .began || g.state == .changed {
                g.isEnabled = false
                g.isEnabled = true
            }
            return
        }
        let p = g.location(in: view)
        let term = view.getTerminal()
        let cols = max(term.cols, 1), rows = max(term.rows, 1)
        // Same true-cell-height fix as `cell(at:in:)`: bounds.height / rows overestimates
        // the true cell height (SwiftTerm floors), which would misplace handle rects and
        // the moving-cell column; prefer `caretFrame` (one true cell), fall back when
        // it's still .zero (caret view not yet created).
        let caret = view.caretFrame
        let cellW = caret.width  > 0 ? caret.width  : view.bounds.width  / CGFloat(cols)
        let cellH = caret.height > 0 ? caret.height : view.bounds.height / CGFloat(rows)

        switch g.state {
        case .began:
            // Compute each endpoint's on-screen rect from the STORED selection positions.
            guard let ends = currentSelectionEnds(in: view) else {
                // Force-cancel via isEnabled bounce, not `g.state = .cancelled` (see the
                // no-active-selection guard above for why).
                g.isEnabled = false
                g.isEnabled = true
                return
            }
            let startRect = cellRect(col: ends.start.col, row: ends.start.row, cellW: cellW, cellH: cellH, in: view)
            let endRect   = cellRect(col: ends.end.col,   row: ends.end.row,   cellW: cellW, cellH: cellH, in: view)
            draggingEnd = SemicolynKit.hitTestHandle(
                point: SelectionHandlePoint(x: Double(p.x), y: Double(p.y)),
                startRect: SelectionHandleRect(x: Double(startRect.origin.x), y: Double(startRect.origin.y),
                                               width: Double(startRect.width), height: Double(startRect.height)),
                endRect: SelectionHandleRect(x: Double(endRect.origin.x), y: Double(endRect.origin.y),
                                             width: Double(endRect.width), height: Double(endRect.height)),
                slop: 22)
            if draggingEnd == nil {
                // not a handle: let content own it (isEnabled bounce, see above)
                g.isEnabled = false
                g.isEnabled = true
                return
            }
            anchoredEnd = (draggingEnd == .start) ? ends.end : ends.start
            callbacks.onSelectPane()   // handle-drag focuses too
            DebugLog.shared.log(.gesture, "gesture:handlePan action=grab end=\(String(describing: draggingEnd))")
        case .changed:
            guard let anchor = anchoredEnd else { return }
            let (_, _, absRow) = cell(at: p, in: view)
            let col = min(cols - 1, max(0, Int(p.x / cellW)))
            let moving = (col: col, row: absRow)
            let o = SemicolynKit.orderedSelection(a: anchor, b: moving)
            applyInclusiveSelection(start: o.start, end: o.end, in: view)
            loupe?.show(around: p, in: view)
        case .ended, .cancelled, .failed:
            anchoredEnd = nil; draggingEnd = nil
            loupe?.hide()
            if g.state == .ended {
                presentEditMenu(at: p, in: view)
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
        // after a dismiss (device report, build 44). Raise it explicitly here in EVERY mode:
        // even an alt-screen/mouse-reporting app needs the keyboard to type.
        if !view.isFirstResponder {
            let ok = view.becomeFirstResponder()
            DebugLog.shared.log(.gesture, "gesture:singleTap becomeFirstResponder=\(ok)")
        }
        let p = g.location(in: view)
        // Tap-inside test for the copy-menu re-summon rule (Topic 3c): a tap ON an active
        // selection re-summons the menu instead of clearing it. Uses the same absolute-row
        // space as `storedStart`/`storedEnd` (see `cell(at:in:)`).
        let tapInside: Bool = {
            guard callbacks.hasSelection(), let s = storedStart, let e = storedEnd else { return false }
            let target = cell(at: p, in: view)
            return SemicolynKit.isWithinSelection(col: target.col, row: target.absoluteRow, start: s, end: e)
        }()
        switch paneTapAction(isActivePane: callbacks.isActivePane(),
                             mode: callbacks.currentMode(),
                             hasSelection: callbacks.hasSelection(),
                             tapInsideSelection: tapInside) {
        case .focusPane:
            callbacks.onSelectPane()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=focus-pane")
        case .active(.reSummonMenu):
            presentEditMenu(at: p, in: view)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=reSummonMenu")
        case .active(.clearSelection):
            callbacks.clearSelection()
            storedStart = nil; storedEnd = nil
            DebugLog.shared.log(.gesture, "gesture:singleTap action=clear")
        case .active(.placeCursor):
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.viewportRow)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.viewportRow))")
        case .yield:
            DebugLog.shared.log(.gesture, "gesture:singleTap action=appOwns mode=\(callbacks.currentMode())")
            return
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        // Word-select runs in every mode: it selects against SwiftTerm's local grid,
        // which under tmux -CC is the currently-visible content. (Pre-#102 alt-screen
        // mis-selection was a tap->cell coordinate bug, since fixed by TapRowMapping +
        // full-height panes; proven on device 2026-07-29.)
        let p = g.location(in: view)
        let (col, viewportRow, absoluteRow) = cell(at: p, in: view)
        let (start, end) = subWordBoundsApp(col: col, row: viewportRow, in: view)
        callbacks.onSelectPane()   // focus-on-select (Topic 1): optimistic local focus + select-pane
        applyInclusiveSelection(start: (col: start, row: absoluteRow), end: (col: end, row: absoluteRow), in: view)
        subordinateSelectionPan(on: view)
        DebugLog.shared.log(.gesture,
            "sel:double loc=\(p) mode=\(callbacks.currentMode()) cell=(\(col),\(viewportRow)) abs=\(absoluteRow) word=(\(start),\(end))")
        DebugLog.shared.log(.gesture, "sel:redraw hasActive=\(view.hasActiveSelection)")
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        // Line-select runs in every mode (see handleDoubleTap).
        let p = g.location(in: view)
        let (_, viewportRow, absoluteRow) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        callbacks.onSelectPane()   // focus-on-select (Topic 1)
        applyInclusiveSelection(start: (col: 0, row: absoluteRow), end: (col: cols - 1, row: absoluteRow), in: view)
        subordinateSelectionPan(on: view)
        DebugLog.shared.log(.gesture,
            "sel:triple loc=\(p) mode=\(callbacks.currentMode()) cell=(\(viewportRow)) abs=\(absoluteRow)")
        DebugLog.shared.log(.gesture, "sel:redraw hasActive=\(view.hasActiveSelection)")
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: g.view))")
        guard g.state == .began else { return }
        callbacks.onLongPressZoom()
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView, view.hasActiveSelection else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        presentEditMenu(at: g.location(in: view), in: view)
    }

    // MARK: Selection helpers

    /// Sub-word bounds on `row` using SwiftTerm's `getCharData` to classify each cell.
    /// `row` is the VIEWPORT row (getCharData adds yDisp itself).
    private func subWordBoundsApp(col: Int, row: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func classOf(_ c: Int) -> CharClass {
            guard c >= 0, c < cols, let cd = term.getCharData(col: c, row: row) else { return .space }
            let ch = cd.getCharacter()
            if ch == " " || ch == "\t" || ch == "\0" { return .space }
            if SemicolynKit.selectionPunctuation.contains(ch) { return .punct }
            return .word
        }
        let r = SemicolynKit.subWordBounds(cols: cols, col: col, classOf: classOf)
        return (r.start, r.end)
    }

    /// Apply a selection given INCLUSIVE grid positions (start..end, both cells included).
    /// SwiftTerm's `setSelectionRange` treats `end.col` as EXCLUSIVE (its highlight fill and
    /// copy path both select `[start.col, end.col)`), so the inclusive end column is passed
    /// as `end.col + 1` to include the last character. `storedStart`/`storedEnd` remain
    /// INCLUSIVE (hit-testing / isWithinSelection / handle rects use inclusive columns).
    private func applyInclusiveSelection(start: (col: Int, row: Int), end: (col: Int, row: Int),
                                         in view: TerminalView) {
        view.setSelectionRange(start: Position(col: start.col, row: start.row),
                               end: Position(col: end.col + 1, row: end.row))
        storedStart = start
        storedEnd = end
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
    ///
    /// NOTE: `handlePan` has no dedicated `GestureRole` case (Task 6 is scoped to this
    /// file only, adding a case means also touching `GestureSimultaneity.swift`), so it
    /// maps to `.other` here and its exclusivity vs `scrollPan`/`switchPan` is handled
    /// directly in the two delegate methods below (identity-checked ahead of the
    /// Kit-policy fallback), NOT via `gesturesMayRecognizeSimultaneously`. Documented
    /// deviation from the "mirror the role/ours pattern" instruction, see task report.
    private func role(of g: UIGestureRecognizer) -> GestureRole {
        if g === terminalView?.panGestureRecognizer { return .scrollPan }
        if g === altScreenPan { return .altScreenPan }
        if g === switchPan { return .switchPan }
        if g === longPress { return .longPress }
        if g === handlePan { return .other }
        if g is UIPinchGestureRecognizer { return .pinch }
        if g is UITapGestureRecognizer { return .tap }
        // A pan that is neither the inherited scroll pan, our alt-screen pan, our handle
        // pan, nor one of our taps/long-press is SwiftTerm's lazily-created selection/mouse
        // pan, the recognizer that hijacks a drag as text selection. Classifying it as
        // `.selectionPan` makes the simultaneity policy exclude it from co-recognizing
        // with the scroll pan.
        if g is UIPanGestureRecognizer { return .selectionPan }
        return .other
    }

    // Simultaneity policy lives in Kit (`gesturesMayRecognizeSimultaneously`): pinch
    // coexists with the 1-finger pan/taps, but the long-press must NOT co-recognize
    // with the scroll pan, otherwise a moving-finger drag was treated as a held-touch
    // text selection (device trace 2026-07-13: every drag started a selection). Making
    // that one pairing exclusive lets the pan cancel the long-press on movement.
    //
    // `handlePan` is excluded from `scrollPan`/`switchPan` directly here (ahead of the
    // Kit policy call), the App-local mirror of the `.selectionPan`/`.scrollPan` Kit
    // exclusion, since `handlePan` has no Kit role (see `role(of:)`).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if isHandlePanVsScrollOrSwitch(g, other) { return false }
        return gesturesMayRecognizeSimultaneously(role(of: g), role(of: other))
    }

    /// Make SwiftTerm's selection/mouse pan *lose* to the native scroll pan, AND make
    /// `scrollPan`/`switchPan` lose to OUR `handlePan`.
    ///
    /// `shouldRecognizeSimultaneouslyWith == false` only stops two pans from co-recognizing;
    /// it does not decide WHICH wins. For the selection pan (an unwanted hijacker) we want
    /// the scroll pan to win, so the selection pan is required to fail first (build-42
    /// device trace). For `handlePan` it's the MIRROR IMAGE: it's the pan we WANT to win
    /// when a touch starts on a handle, so `scrollPan`/`switchPan` are the ones required to
    /// fail here instead, delivered to them (`g` = scrollPan/switchPan, `other` = handlePan).
    /// `handlePan.began` hit-tests and self-cancels on a non-handle touch, so requiring the
    /// content pans to wait on it only costs the recognition-delay window, not a broken drag.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        if other === handlePan, role(of: g) == .scrollPan || role(of: g) == .switchPan {
            return true
        }
        guard role(of: g) == .selectionPan else { return false }
        return role(of: other) == .scrollPan || role(of: other) == .switchPan
    }

    /// True when `(g, other)` is the `handlePan` vs `scrollPan`/`switchPan` pairing in
    /// either order, the App-local exclusion `role(of:)`/Kit policy can't express because
    /// `handlePan` maps to `.other` (see `role(of:)`).
    private func isHandlePanVsScrollOrSwitch(_ g: UIGestureRecognizer, _ other: UIGestureRecognizer) -> Bool {
        let pair = Set([ObjectIdentifier(g), ObjectIdentifier(other)])
        guard let handlePan, let scrollPan = terminalView?.panGestureRecognizer, let switchPan else { return false }
        return pair == Set([ObjectIdentifier(handlePan), ObjectIdentifier(scrollPan)])
            || pair == Set([ObjectIdentifier(handlePan), ObjectIdentifier(switchPan)])
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
            items.append(UIAction(title: "Paste") { [weak self] _ in
                guard let self, let text = UIPasteboard.general.string, !text.isEmpty else { return }
                // Always bracket: apps that enabled bracketed paste get delimited text; apps
                // that did not simply ignore the ESC[200~/ESC[201~ markers.
                let bytes = SemicolynKit.bracketedPasteBytes(text, bracketed: true)
                self.callbacks.sendBytes(bytes)
            })
        }
        return UIMenu(children: items.isEmpty ? suggestedActions : items)
    }
}
