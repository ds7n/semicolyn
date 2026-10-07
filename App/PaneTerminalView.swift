// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

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

    /// Full geometry on EVERY layout for the single terminal view (`TerminalScreen`). A tmux
    /// window switch doesn't change SwiftTerm's grid, so `sizeChanged` never fires for it;
    /// logging here captures the terminal's placement continuously. `geo:pane` = this view;
    /// correlate with the surrounding `transport=` and `geo:layout` lines.
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

    /// Issue 3 diagnosis (device 2026-08-06): scrolling is dead on the raw path (ET) but
    /// works on raw SSH. The mount-time recognizer observer showed ZERO gr-observe on an
    /// ET swipe, so the native scroll pan never began, the touch is swallowed before any
    /// observed recognizer sees it, and SwiftTerm's LAZILY-created selection/mouse pans are
    /// not observed (they don't exist at mount). Log the FULL live recognizer roster and the
    /// scroll-relevant state at the instant a touch lands, so a device swipe names exactly
    /// which recognizers are present and enabled (incl. lazy pans) and whether native scroll
    /// is even eligible. Diagnostic only: calls super, changes no behavior; gated on .gesture.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard DebugLog.shared.isEnabled(.gesture) else { return }
        let grs = gestureRecognizers ?? []
        let roster = grs.map { gr -> String in
            let kind = gr === panGestureRecognizer ? "nativePan"
                : (gr is UIPanGestureRecognizer ? "pan(\(type(of: gr)))" : "\(type(of: gr))")
            return "\(kind):en=\(gr.isEnabled ? 1 : 0)/st=\(gr.state.rawValue)"
        }.joined(separator: " ")
        DebugLog.shared.log(.gesture,
            "touch:begin n=\(touches.count) scrollEnabled=\(isScrollEnabled) delaysContent=\(delaysContentTouches) "
            + "fr=\(isFirstResponder) panEnabled=\(panGestureRecognizer.isEnabled) "
            + "contentSize=\(Int(contentSize.height)) frameH=\(Int(frame.height)) grCount=\(grs.count) [\(roster)]")
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onModeRelevantChange?(.bufferChanged, source)
    }
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onModeRelevantChange?(.mouseChanged, source)
    }

    // MARK: Native text-interaction suppression
    //
    // `TerminalView` conforms to `UITextInput` (+ `UIKeyInput`) and becomes first
    // responder for keyboard input. On iOS 13+, UIKit installs its own text-interaction
    // gesture stack (loupe, selection drag, grab handles) on such a view, recognizers
    // owned by UIKit, not by SwiftTerm and not by us. That stack grabbed the single-finger
    // drag and drew a SYSTEM-tinted selection (a DIFFERENT color than SwiftTerm's own
    // double/triple-tap selection, device report, build 43) while the terminal's inherited
    // `UIScrollView` pan never even began (zero `gr:scrollPan began` logs).
    //
    // Primary fix: `editingInteractionConfiguration = .none`, the documented public
    // `UIResponder` opt-out (iOS 13+) for system editing/selection interaction gestures on
    // a view whose own gestures collide with them.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    // Single gesture engine (spec 2026-10-04): every touch goes through OUR
    // `TerminalTouchRecognizer` (plus the stock pinch). Every other tap, long-press and pan
    // recognizer, SwiftTerm's own (including the selection / mouse pans it re-creates each
    // time tmux re-sends mouse mode, device build 179) and UIKit's scroll-view and
    // text-interaction ones, is disabled the moment it is added, so nothing can compete.
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        let grClass = String(describing: type(of: gestureRecognizer))
        let delegateClass = gestureRecognizer.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        let ours = gestureRecognizer is TerminalTouchRecognizer || gestureRecognizer is UIPinchGestureRecognizer
        let competes = gestureRecognizer is UITapGestureRecognizer
            || gestureRecognizer is UILongPressGestureRecognizer
            || gestureRecognizer is UIPanGestureRecognizer
            || grClass.hasPrefix("UIScrollView")
            || delegateClass.contains("TextInteraction")
            || delegateClass.contains("TextSelection")
        if !ours && competes { gestureRecognizer.isEnabled = false }
        DebugLog.shared.log(.gesture, "addGR: \(grClass) delegate=\(delegateClass) disabled=\(!ours && competes)")
    }
}

