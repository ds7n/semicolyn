// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm

/// SwiftTerm delivers `bufferActivated` / `mouseModeChanged` (the alt-screen and
/// mouse-mode transition events) to the `TerminalView` INSTANCE via the emulator
/// `TerminalDelegate` — NOT to the app's `TerminalViewDelegate`. `TerminalView`
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
    // gesture stack (loupe, selection drag, grab handles) on such a view — recognizers
    // owned by UIKit, not by SwiftTerm and not by us. That stack grabbed the single-finger
    // drag and drew a SYSTEM-tinted selection (a DIFFERENT color than SwiftTerm's own
    // double/triple-tap selection — device report, build 43) while the terminal's inherited
    // `UIScrollView` pan never even began (zero `gr:scrollPan began` logs). Our
    // `GestureSimultaneity` policy and `sweep2` only touch SwiftTerm's OWN pans, so they
    // can't reach these.
    //
    // Primary fix: `editingInteractionConfiguration = .none` — the documented public
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

        // The recognizer classes are private, so match on the delegate class name — the
        // only public signal. Conservative substring match tolerant of UIKit renames.
        if delegateClass.contains("UITextInteraction")
            || delegateClass.contains("TextSelection")
            || delegateClass.contains("TextInteraction") {
            gestureRecognizer.isEnabled = false
            DebugLog.shared.log(.gesture, "addGR: DISABLED native text-interaction recognizer \(grClass)")
        }
    }
}
