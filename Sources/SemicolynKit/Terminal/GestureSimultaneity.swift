// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The role a terminal gesture recognizer plays, abstracted from UIKit so the
/// simultaneity policy is a pure, testable decision (the App layer maps its
/// `UIGestureRecognizer` instances to these).
public enum GestureRole: Hashable, Sendable, CaseIterable {
    /// The terminal view's inherited `UIScrollView` pan, owns vertical scroll and
    /// the horizontal window-switch drag.
    case scrollPan
    /// Our long-press (pane-zoom). Must fire ONLY on a still finger.
    case longPress
    /// Two-finger pinch (font zoom).
    case pinch
    /// A tap (single / double / triple / two-finger).
    case tap
    /// SwiftTerm's lazily-created selection/mouse pan (`panSelectionGesture` /
    /// `panMouseGesture`), an extra `UIPanGestureRecognizer` it attaches on demand
    /// (first selection / double-tap). It drives text selection on a single-finger
    /// drag and must lose to the scroll pan, or a plain drag selects instead of
    /// scrolling.
    case selectionPan
    /// OUR alt-screen drag pan, a `UIPanGestureRecognizer` we own, enabled ONLY in
    /// `.appOwnsInput` (where the native scroll pan is parked via `isScrollEnabled =
    /// false`). It translates a vertical drag into arrow-key runs to the foreground app
    /// (xterm Alternate-Scroll). Never live at the same time as `scrollPan` (mode-gated),
    /// but must be mutually exclusive with the long-press for the same held-drag hazard.
    case altScreenPan
    /// OUR always-on horizontal window-switch pan (`.localScroll`/`.mouseReporting`). A
    /// UIPanGestureRecognizer we own, so the swipe never depends on SwiftTerm's scroll-view
    /// state (a fresh pane's native scroll pan does not track a horizontal drag). Coexists
    /// with the scroll pan (orthogonal axes: horizontal here, vertical there).
    case switchPan
    /// OUR selection-handle drag pan, enabled only while a selection is active. When a touch
    /// starts on a handle it must OWN the drag: no content drag owner, long-press or
    /// SwiftTerm selection pan may run on the same touch (device build 175: dragging a
    /// handle inside tmux also switched windows via the alt-screen pan).
    case handlePan
    /// Any other recognizer we don't model explicitly.
    case other
}

public extension GestureRole {
    /// Whether this recognizer owns a one-finger CONTENT drag (scroll, window swipe, or the
    /// alt-screen arrow/wheel drag). Exhaustive on purpose: a new role must be classified
    /// here, and every drag-ownership rule below is derived from this, so a new drag owner
    /// inherits the long-press / selection-pan / handle-drag rules instead of shipping a gap.
    var isContentDragOwner: Bool {
        switch self {
        case .scrollPan, .switchPan, .altScreenPan:
            return true
        case .longPress, .pinch, .tap, .selectionPan, .handlePan, .other:
            return false
        }
    }
}

/// Whether two recognizers may recognize *simultaneously*. The key rule, from a
/// device trace (2026-07-13): a long-press must NOT co-recognize with the scroll
/// pan, when it did, a moving-finger drag was treated as a held-touch text
/// selection (drag-start = selection anchor, drag = selection extension), the
/// "every drag selects text" bug. Returning `false` for that pairing lets the pan
/// cancel the long-press on movement (default UIKit behavior the old blanket-`true`
/// delegate was suppressing). Pinch still coexists with everything (2-finger vs the
/// 1-finger pan/taps), so a stray second finger can't kill scroll.
public func gesturesMayRecognizeSimultaneously(_ a: GestureRole, _ b: GestureRole) -> Bool {
    if a == b { return true }
    for (x, y) in [(a, b), (b, a)] {
        // Held-then-drag hazard (device trace 2026-07-13): a long-press must never
        // co-recognize with a content drag, or a moving finger anchors a selection / fires
        // zoom instead of scrolling. Exclusivity lets the pan cancel the long-press on motion.
        if x == .longPress && y.isContentDragOwner { return false }
        // Build-42 bug: SwiftTerm's selection/mouse pan must never drive a content drag as a
        // text selection (it won arbitration before our handlers ran).
        if x == .selectionPan && y.isContentDragOwner { return false }
        // A handle drag owns its touch outright: no content drag (window switch), no
        // long-press (zoom mid-selection) and no SwiftTerm selection pan alongside it.
        if x == .handlePan && (y.isContentDragOwner || y == .longPress || y == .selectionPan) {
            return false
        }
    }
    // Everything else coexists: pinch is two-finger, taps fail on movement, and the content
    // drag owners are mode-gated (only one enabled) or orthogonal (scroll vs switch).
    return true
}

/// Whether recognizer `g` must wait for `other` to fail before it may begin.
///
/// - A content drag owner waits for the handle drag, but ONLY while a selection exists
///   (handles on screen). The handle drag self-cancels off a handle, so the wait costs only
///   the recognition window; with no selection it would stall the pan for nothing (device
///   build 117 lost native scrolling that way).
/// - SwiftTerm's selection pan always waits for every content drag owner, so a plain drag
///   scrolls / swipes instead of selecting.
public func gestureMustWaitForFailure(_ g: GestureRole, of other: GestureRole,
                                      hasActiveSelection: Bool) -> Bool {
    if g.isContentDragOwner && other == .handlePan { return hasActiveSelection }
    if g == .selectionPan && other.isContentDragOwner { return true }
    return false
}
