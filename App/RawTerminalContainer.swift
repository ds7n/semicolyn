// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`), mirroring
/// `TmuxPaneContainer.ContainerView`. The `PaneTerminalView` (a `UIScrollView`) is an
/// absolutely-framed SUBVIEW; this container is what SwiftUI sizes. Because the container
/// is the representable leaf and never self-mutates its own frame, its `bounds` and
/// `keyboardLayoutGuide` resolve in the TRUE slot (~499pt), not the full window (~1001pt).
///
/// This removes the coordinate-space mismatch at its source: previously `TerminalScreen`
/// returned the `PaneTerminalView` directly, so SwiftUI sized the scroll view to ~1001pt
/// while `layoutSubviews` self-mutated it to 499, and `keyboardLayoutGuide.layoutFrame.minY`
/// came back in window space (1001). That drove the PR #121 scroll-dead + keybar-hidden bugs.
/// See `docs/superpowers/specs/2026-08-08-raw-terminal-container-wrap-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, framed to the keybar-reduced usable height each layout.
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        // Manual framing in layoutSubviews owns the child's frame; keep the UIKit
        // default translatesAutoresizingMaskIntoConstraints = true (no Auto Layout).
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Frame the child to the container width and the keybar-REDUCED usable height. Prefer the
    /// real keyboard/keybar top from `keyboardLayoutGuide` (re-lays-out correctly post-app-switch);
    /// fall back to the measured-keybar-height reduction when the guide has no usable frame. This
    /// is the SAME usable-height source `TmuxPaneContainer` uses, now read from the correct space.
    override func layoutSubviews() {
        super.layoutSubviews()
        let raw = Double(bounds.height)
        let usableH: Double = {
            if let top = keyboardTopInContainer() {
                return usableHeightFromKeyboardTop(rawHeight: raw, keyboardTopY: top)
            }
            return visibleTerminalHeight(rawHeight: raw,
                                         keybarHeight: Double(firstResponderKeybarHeight()))
        }()
        terminal.frame = CGRect(x: 0, y: 0, width: bounds.width, height: usableH)

        // Container-space geometry diagnostic. The direct proof the root cause is gone:
        // `guideTop` should now read ~499 (the slot), not ~1001 (the window).
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let guideTop = keyboardTopInContainer()
        let accH = (terminal.inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1
        let cf = terminal.frame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "guideTop=\(guideTop.map { String(format: "%.0f", $0) } ?? "nil") "
            + "fr=\(terminal.isFirstResponder) accH=\(String(format: "%.0f", accH)) "
            + "usableH=\(String(format: "%.0f", usableH)) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height))")
    }

    /// The keyboard/keybar top edge in THIS view's coordinate space, via `keyboardLayoutGuide`
    /// (iOS 15+, auto-tracks the keyboard + its inputAccessoryView across show/hide/animation
    /// and the post-app-switch re-layout a measured keybar height missed). Returns nil when the
    /// keyboard is down / the guide has no usable frame, so the caller falls back to full height.
    /// Copied verbatim from `TmuxPaneContainer.ContainerView.keyboardTopInContainer()`.
    private func keyboardTopInContainer() -> Double? {
        let f = keyboardLayoutGuide.layoutFrame
        guard f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0 else { return nil }
        return Double(f.minY)
    }

    /// The keybar (`inputAccessoryView`) height of the child terminal when it is first responder
    /// (iOS shows exactly that view's accessory). Returns -1 when the terminal is not first
    /// responder (keyboard down, no accessory). Copied from
    /// `TmuxPaneContainer.ContainerView.firstResponderKeybarHeight()` (single-child variant).
    private func firstResponderKeybarHeight() -> CGFloat {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView as? KeybarInputAccessory else { return -1 }
        return acc.intrinsicContentSize.height
    }
}
