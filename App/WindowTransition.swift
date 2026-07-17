// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Two-phase window-switch slide (design: 2026-07-17-window-switch-transition-design.md).
/// On swipe release, `slideOut` translates the current pane-content view off-screen in the
/// swipe direction (responsive, independent of tmux). `beginPending` records that the NEW
/// window should slide IN from the opposite edge once tmux delivers it; `apply` calls
/// `consumePendingSlideIn` when the active window changes. A timeout clears a stuck pending
/// transition (slow/failed switch) so the content never sticks off-screen.
@MainActor
final class WindowTransition {
    private(set) var pendingInEdge: SlideEdge?
    private var timeoutItem: DispatchWorkItem?

    /// Duration of each slide phase.
    private let duration: TimeInterval = 0.22

    /// `nonisolated` so the (nonisolated) `Coordinator` — an `NSObject`/`TerminalViewDelegate`,
    /// which cannot be `@MainActor` — can construct this as a stored property. The init only
    /// sets trivial defaults (no UIView / main-actor work); every method that touches UIView
    /// stays `@MainActor`. Without this, `let windowTransition = WindowTransition()` in the
    /// nonisolated Coordinator fails: "call to main actor-isolated initializer in a
    /// synchronous nonisolated context" (macOS CI, 2026-07-17).
    nonisolated init() {}

    /// Slide the current content OUT toward `edge`. `completion` runs when the animation ends.
    func slideOut(_ edge: SlideEdge, view: UIView, width: CGFloat, completion: (() -> Void)? = nil) {
        let dx: CGFloat = (edge == .left) ? -width : width
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn], animations: {
            view.transform = CGAffineTransform(translationX: dx, y: 0)
        }, completion: { _ in completion?() })
    }

    /// Record that the incoming window should slide IN from `inEdge`, arming a timeout that
    /// invokes `onTimeout` (which should reset any lingering transform) if no slide-in arrives.
    func beginPending(inEdge: SlideEdge, timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        pendingInEdge = inEdge
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingInEdge != nil else { return }
            self.pendingInEdge = nil
            onTimeout()
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// If a slide-in is pending, start `view` off-screen at the pending edge and animate it to
    /// identity; clear pending + cancel the timeout. Returns whether a slide-in ran.
    @discardableResult
    func consumePendingSlideIn(view: UIView, width: CGFloat) -> Bool {
        guard let edge = pendingInEdge else { return false }
        pendingInEdge = nil
        timeoutItem?.cancel(); timeoutItem = nil
        let startDx: CGFloat = (edge == .left) ? -width : width
        view.transform = CGAffineTransform(translationX: startDx, y: 0)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut], animations: {
            view.transform = .identity
        })
        return true
    }
}
