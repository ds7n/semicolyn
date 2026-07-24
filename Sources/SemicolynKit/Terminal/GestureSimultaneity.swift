// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The role a terminal gesture recognizer plays, abstracted from UIKit so the
/// simultaneity policy is a pure, testable decision (the App layer maps its
/// `UIGestureRecognizer` instances to these).
public enum GestureRole: Hashable, Sendable {
    /// The terminal view's inherited `UIScrollView` pan — owns vertical scroll and
    /// the horizontal window-switch drag.
    case scrollPan
    /// Our long-press (pane-zoom). Must fire ONLY on a still finger.
    case longPress
    /// Two-finger pinch (font zoom).
    case pinch
    /// A tap (single / double / triple / two-finger).
    case tap
    /// SwiftTerm's lazily-created selection/mouse pan (`panSelectionGesture` /
    /// `panMouseGesture`) — an extra `UIPanGestureRecognizer` it attaches on demand
    /// (first selection / double-tap). It drives text selection on a single-finger
    /// drag and must lose to the scroll pan, or a plain drag selects instead of
    /// scrolling.
    case selectionPan
    /// OUR alt-screen drag pan — a `UIPanGestureRecognizer` we own, enabled ONLY in
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
    /// Any other recognizer we don't model explicitly.
    case other
}

/// Whether two recognizers may recognize *simultaneously*. The key rule, from a
/// device trace (2026-07-13): a long-press must NOT co-recognize with the scroll
/// pan — when it did, a moving-finger drag was treated as a held-touch text
/// selection (drag-start = selection anchor, drag = selection extension), the
/// "every drag selects text" bug. Returning `false` for that pairing lets the pan
/// cancel the long-press on movement (default UIKit behavior the old blanket-`true`
/// delegate was suppressing). Pinch still coexists with everything (2-finger vs the
/// 1-finger pan/taps), so a stray second finger can't kill scroll.
public func gesturesMayRecognizeSimultaneously(_ a: GestureRole, _ b: GestureRole) -> Bool {
    let pair = Set([a, b])
    // The bug: long-press + scroll pan must be mutually exclusive.
    if pair == Set([.longPress, .scrollPan]) { return false }
    // The build-42 bug: SwiftTerm's selection/mouse pan + scroll pan must be mutually
    // exclusive, or a plain vertical drag is driven as a text selection by SwiftTerm's
    // own recognizer (our handlers never run — zero `.gesture` logs during the drag).
    // The old `sweep2` disable-on-drag-start couldn't catch this: it's gated on the
    // scroll pan's `.began`, which never fires when the selection pan wins arbitration.
    if pair == Set([.selectionPan, .scrollPan]) { return false }
    // Our alt-screen drag pan must NOT co-recognize with the long-press, for the same
    // held-then-drag hazard as the scroll pan: a long-press that fires as the finger
    // starts moving would anchor a text selection instead of letting the drag emit
    // arrows. Making the pairing exclusive lets the pan cancel the long-press on motion.
    if pair == Set([.altScreenPan, .longPress]) { return false }
    // The switch pan must NOT co-recognize with the selection pan (a switch drag must never
    // be hijacked into a text selection) nor the long-press (held-then-drag hazard), matching
    // the scrollPan exclusions. It DOES coexist with the scroll pan (orthogonal axes) and
    // pinch (2-finger), which fall through to the default `true`.
    if pair == Set([.selectionPan, .switchPan]) { return false }
    if pair == Set([.switchPan, .longPress]) { return false }
    return true
}
