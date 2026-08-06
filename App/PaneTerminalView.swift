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

    /// True ONLY on the raw single-terminal path (`TerminalScreen`), where SwiftUI
    /// sizes this view to the full slot and the keybar (`inputAccessoryView`) floats
    /// over the bottom rows. When set, `layoutSubviews` insets the view's frame height
    /// to the visible area above the keybar so SwiftTerm's row count (frame.height /
    /// cellHeight) equals the VISIBLE rows and no row renders behind the keybar. Left
    /// false on the -CC path (`TmuxPaneContainer`), which already sizes each pane frame
    /// to the usable height externally, so this view must NOT double-inset there.
    var appliesOwnKeybarInset = false

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
        // Raw-path keybar inset (device 2026-08-06): SwiftTerm derives its row count
        // from frame.height / cellHeight (AppleTerminalView v1.15.0), so a full-bounds
        // frame renders ~kbH/cellH bottom rows behind the floating keybar. Reduce the
        // frame height to the visible area above the keybar. Mirror TmuxPaneContainer's
        // usableH: prefer the real keybar top from keyboardLayoutGuide (re-lays-out post
        // app-switch), else the measured keybar-height reduction. Gated to the raw path;
        // the -CC path insets its panes externally and must not be double-inset.
        if appliesOwnKeybarInset {
            // Read the full slot height from the SwiftUI host (superview), NOT self.bounds:
            // SwiftTerm's frame setter runs processSizeChange synchronously, so reading the
            // height we then mutate on the SAME view would ratchet down each pass on the
            // fallback branch. The superview is SwiftUI-sized and never mutated here, so it
            // is a stable `raw` (mirrors TmuxPaneContainer reading the container, not the pane).
            let raw = Double(superview?.bounds.height ?? bounds.height)
            let guideTop: Double? = {
                let f = keyboardLayoutGuide.layoutFrame
                guard f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0 else { return nil }
                return Double(f.minY)
            }()
            let usableH: Double = {
                if let guideTop {
                    return usableHeightFromKeyboardTop(rawHeight: raw, keyboardTopY: guideTop)
                }
                let kbH = isFirstResponder
                    ? Double((inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1)
                    : -1
                return visibleTerminalHeight(rawHeight: raw, keybarHeight: kbH)
            }()
            // Only mutate when it actually differs (a re-entrant pass with height already
            // == usableH must be a no-op, or layoutSubviews loops). Keep origin/width from
            // the SwiftUI slot; shrink height only. The keybar floats over the freed region.
            if usableH > 0, abs(usableH - Double(frame.height)) > 0.5 {
                frame.size.height = CGFloat(usableH)
            }
        }
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
