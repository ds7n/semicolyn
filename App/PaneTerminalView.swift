// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm

/// SwiftTerm delivers `bufferActivated` / `mouseModeChanged` (the alt-screen and
/// mouse-mode transition events) to the `TerminalView` INSTANCE via the emulator
/// `TerminalDelegate`, NOT to the app's `TerminalViewDelegate`. `TerminalView`
/// declares them `open` for exactly this: subclass and override. We `super`-call
/// first (preserve SwiftTerm's own scroller / mouse-pan-gesture side effects), then
/// hand the live `Terminal` to `onModeRelevantChange`, which each mount wires to its
/// `PaneModeTracker.recompute(...)`.

/// Which mode-relevant SwiftTerm event fired. `bufferActivated` is a real alternate-screen
/// (`?1049`) transition, so the live `isCurrentBufferAlternate` flag is authoritative at that
/// instant. `mouseModeChanged` is NOT an alt-screen transition, so the tracked alt-state must
/// be preserved across it (see `PaneModeTracker.AltSource`).
enum ModeRelevantEvent { case bufferChanged, mouseChanged }

final class PaneTerminalView: TerminalView {
    /// Set by the mount right after construction. Called on every alt-screen or
    /// mouse-mode transition with this view's emulator terminal.
    var onModeRelevantChange: ((ModeRelevantEvent, Terminal) -> Void)?

    /// Full geometry on EVERY layout, in BOTH the raw-SSH (`TerminalScreen`) and tmux -CC
    /// (`TmuxPaneContainer`) paths, this is the shared pane view for both. The `.geometry`
    /// diagnostic previously only fired in the -CC container's `layoutSubviews`, so the WORKING
    /// raw path emitted nothing to diff against (a raw-mode tmux window switch doesn't change
    /// SwiftTerm's grid, so `sizeChanged` never fired either). Logging here captures the raw
    /// path continuously so its terminal placement (no keybar gap) can be compared field-for-
    /// field with the -CC path's (the ~56px keybar gap). `geo:pane` = this view; correlate with
    /// the surrounding `transport=RAW` vs `geo:layout` lines to know which mode produced it.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let f = frame, co = contentOffset, cs = contentSize
        let ci = contentInset, ai = adjustedContentInset
        let t = getTerminal(), b = t.buffer
        let sv = superview
        DebugLog.shared.log(.geometry,
            "geo:pane frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)) "
            + "vbounds=\(Int(bounds.width))x\(Int(bounds.height)) super=\(sv.map { String(describing: type(of: $0)) } ?? "nil")"
            + "(\(sv.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-")) "
            + "grid=\(t.cols)x\(t.rows) topRow\(t.getTopVisibleRow()) yDisp\(b.yDisp) scroll\(b.scrollTop)..\(b.scrollBottom) "
            + "contentSize=\(Int(cs.width))x\(Int(cs.height)) offset=\(Int(co.x)),\(Int(co.y)) "
            + "inset=(t\(Int(ci.top)),b\(Int(ci.bottom))) adjInset=(t\(Int(ai.top)),b\(Int(ai.bottom))) "
            + "fr=\(isFirstResponder) clip=\(clipsToBounds) "
            + "accH=\(String(format: "%.0f", (inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1)) "
            + "accFrameH=\(inputAccessoryView.map { Int($0.frame.height) } ?? -1)")
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onModeRelevantChange?(.bufferChanged, source)
    }
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onModeRelevantChange?(.mouseChanged, source)
    }

    /// Set true by the gesture controller right after a selection is made, so the
    /// NEXT SwiftTerm selection-state change logs the live selection state (spec 3g
    /// candidate #1: selection cleared by a mode-transition / tmux -CC repaint between
    /// set and draw). One-shot: cleared after it fires once.
    var armSelectionRepaintDiag: Bool = false
    /// The mode string captured at arm time, echoed on the repaint line for
    /// normal-vs-alt comparison.
    var armSelectionRepaintMode: String = "?"

    /// Diagnostic probe only; behavior must not change, so `super.selectionChanged` is
    /// called FIRST and unconditionally. `draw(_:)` is `public` (not `open`) in SwiftTerm
    /// so it cannot be overridden cross-module; `selectionChanged` IS `open` and fires
    /// whenever SwiftTerm's selection state changes and its repaint is scheduled, a
    /// directly-observable signal for whether the selection survived from `set`
    /// (device 2026-07-29: no visible highlight).
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if armSelectionRepaintDiag {
            armSelectionRepaintDiag = false
            DebugLog.shared.log(.selection,
                SelectionDiagnostics.snapshot(self, phase: "repaint", mode: armSelectionRepaintMode))
        }
    }

    // MARK: Native text-interaction suppression
    //
    // `TerminalView` conforms to `UITextInput` (+ `UIKeyInput`) and becomes first
    // responder for keyboard input. On iOS 13+, UIKit installs its own text-interaction
    // gesture stack (loupe, selection drag, grab handles) on such a view, recognizers
    // owned by UIKit, not by SwiftTerm and not by us. That stack grabbed the single-finger
    // drag and drew a SYSTEM-tinted selection (a DIFFERENT color than SwiftTerm's own
    // double/triple-tap selection, device report, build 43) while the terminal's inherited
    // `UIScrollView` pan never even began (zero `gr:scrollPan began` logs). Our
    // `GestureSimultaneity` policy and `sweep2` only touch SwiftTerm's OWN pans, so they
    // can't reach these.
    //
    // Primary fix: `editingInteractionConfiguration = .none`, the documented public
    // `UIResponder` opt-out (iOS 13+) for system editing/selection interaction gestures on
    // a view whose own gestures collide with them.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    // Belt-and-suspenders + instrumentation: every recognizer UIKit adds arrives through
    // `addGestureRecognizer`. Log each one (class + owning-delegate class, gated on
    // `.gesture`) so a device trace is DEFINITIVE about what grabbed the drag, and disable
    // any that a text-interaction delegate owns in case `.none` doesn't cover the
    // single-finger selection drag on this iOS. Our own recognizers and the inherited
    // scroll pan aren't added with a text-interaction delegate, so they're unaffected.
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)

        let grClass = String(describing: type(of: gestureRecognizer))
        let delegateClass = gestureRecognizer.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        DebugLog.shared.log(.gesture, "addGR: \(grClass) delegate=\(delegateClass)")

        // The recognizer classes are private, so match on the delegate class name, the
        // only public signal. Conservative substring match tolerant of UIKit renames.
        if delegateClass.contains("UITextInteraction")
            || delegateClass.contains("TextSelection")
            || delegateClass.contains("TextInteraction") {
            gestureRecognizer.isEnabled = false
            DebugLog.shared.log(.gesture, "addGR: DISABLED native text-interaction recognizer \(grClass)")
        }
    }
}
