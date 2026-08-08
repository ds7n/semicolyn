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

        // Container-space geometry diagnostic. DIAGNOSTIC-ONLY probe (2026-08-08, build 120
        // showed the keybar hiding rows AGAIN): device build 120 logged guideTop=499 on a
        // 499-tall container while a 56pt keybar was up, so `keyboardLayoutGuide` reports the
        // container's OWN bottom edge (zero keyboard reservation) whenever the on-screen
        // keyboard is dismissed but our `inputAccessoryView` keybar is still shown. That is the
        // recurring root cause: the guide (and the measured accH) are both PROXIES for the keybar
        // position, each wrong in a different state, and every prior fix just traded one for the
        // other. `kbTopViaFrame` is the HYPOTHESIS under test: the accessory's REAL frame top,
        // converted into this container's space (the same computation the -CC path already does
        // for its `kbTopY` log). If on device `kbTopViaFrame` reads ~443 while `guideTop`=499,
        // the converted frame is the always-correct signal and the real fix drives layout from
        // it. LAYOUT IS UNCHANGED by this probe: `usableH` above still uses guideTop/accH as
        // shipped; we only OBSERVE kbTopViaFrame to prove the hypothesis before the fix.
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let guideTop = keyboardTopInContainer()
        let accH = (terminal.inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1
        let kbTopViaFrame = keybarTopInContainerViaFrame()
        let cf = terminal.frame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "guideTop=\(guideTop.map { String(format: "%.0f", $0) } ?? "nil") "
            + "kbTopViaFrame=\(kbTopViaFrame.map { String(format: "%.0f", $0) } ?? "nil") "
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

    /// DIAGNOSTIC-ONLY (2026-08-08): the keybar accessory's REAL top edge, converted from its own
    /// UIKit window into THIS container's coordinate space. The `inputAccessoryView` is hosted in a
    /// separate window (not a subview of this container), so its raw `frame.minY` is in that window's
    /// space and is not directly comparable to `bounds`. `self.convert(_:from: acc.superview)` maps it
    /// into container space, exactly as `TmuxPaneContainer.logGeometry` computes its `kbTopY`. This is
    /// the hypothesis under test for the root-cause fix: unlike `keyboardLayoutGuide` (which reports
    /// bounds-bottom when the on-screen keyboard is down but our keybar is up) and unlike the measured
    /// `accH` (valid only while first responder + self-sized), the converted frame top should be the
    /// keybar's true position in EVERY state. Returns nil when there is no shown accessory. NOT YET
    /// used to drive layout; the fix adopts it once a device capture confirms it reads ~443 when the
    /// guide reads 499.
    private func keybarTopInContainerViaFrame() -> Double? {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView,
              let accSuper = acc.superview else { return nil }
        let topInContainer = convert(CGPoint(x: acc.frame.minX, y: acc.frame.minY), from: accSuper).y
        guard topInContainer.isFinite, topInContainer > 0 else { return nil }
        return Double(topInContainer)
    }
}
