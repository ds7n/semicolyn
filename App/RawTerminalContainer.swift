// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`). The `PaneTerminalView`
/// (a `UIScrollView`) is an Auto-Layout-pinned SUBVIEW; this container is what SwiftUI sizes. The
/// child is pinned to the container's own leading/trailing/top edges, and its bottom-constraint
/// constant is driven each layout pass so the child's bottom edge lands exactly at the keybar's
/// top, derived from WINDOW-SPACE geometry (the keybar accessory's real top in window space minus
/// this container's top in window space, `rawTerminalChildHeight`).
///
/// Why window-space and not a subtraction from `bounds`: device forensics (2026-08-09) proved the
/// container's `bounds` is AMBIGUOUS, after an app-switch SwiftUI hands a keybar-EXCLUDED bounds
/// (~431), on first connect a keybar-INCLUDED bounds (~499), and NO same-window height signal
/// (`bounds`, `keyboardLayoutGuide.layoutFrame.minY` which equals `bounds`, `safeAreaInsets` which
/// is zero) distinguishes the two. So every prior fix that subtracted a keybar height from `bounds`
/// (~7 of them) was correct in one regime and wrong in the other (gap or hidden rows). The keybar
/// accessory's real converted top is the one signal correct in BOTH regimes. When that geometry is
/// untrustworthy (the accessory is hosted in a separate window and can be mid-animation), the pass
/// HOLDS the last-known-good height rather than fill `bounds` (which would hide rows in the
/// keybar-included regime). A bidirectional invariant tripwire logs any residual gap/hidden-rows.
/// See `docs/superpowers/specs/2026-08-08-keybar-safearea-reservation-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, pinned to the container's own edges (Auto Layout frames it).
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?
    /// The child height last applied via `bottomConstraint`, so we only mutate the constant (which
    /// triggers a layout pass) when it actually changes, avoiding a layout feedback loop. Also the
    /// LAST-KNOWN-GOOD height: when a layout pass cannot trust the window-space geometry (the keybar
    /// accessory is mid-animation / not yet reachable), we HOLD this value rather than fall back to
    /// filling `bounds` (which hides rows in the keybar-included regime). `-1` = never set yet.
    private var lastChildHeight: CGFloat = -1
    /// The child's bottom pin, whose `constant` is driven so the child's bottom edge lands exactly
    /// at the keybar's top (from window-space geometry), lifting it above the keybar band.
    private var bottomConstraint: NSLayoutConstraint!

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // Pin the child to self's own edges (NOT safeAreaLayoutGuide): the bottom constraint's
        // constant is driven from window-space keybar geometry in layoutSubviews, so the child's
        // bottom edge lands exactly at the keybar's top in every state.
        bottomConstraint = terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            bottomConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Derive the child height from WINDOW-SPACE keybar geometry, NOT from `bounds` (which is
        // ambiguous: sometimes it already excludes the keybar band, sometimes it includes it, and
        // no same-window height signal distinguishes the two, device forensics 2026-08-09). The
        // keybar accessory's REAL top in window space, relative to this container's top in window
        // space, is the one signal that is correct in both regimes. `rawTerminalChildHeight`
        // returns nil when that geometry is untrustworthy (accessory mid-animation / unreachable),
        // in which case we HOLD the last-known-good height rather than fill bounds (which would
        // hide rows in the keybar-included regime).
        let accH = Double(firstResponderKeybarHeight())
        let win = window
        let containerTopY = win.map { Double(convert(CGPoint.zero, to: $0).y) }
        let accessoryTopY: Double? = {
            guard terminal.isFirstResponder, let acc = terminal.inputAccessoryView,
                  let accSuper = acc.superview, let w = win else { return nil }
            let y = w.convert(CGPoint(x: acc.frame.minX, y: acc.frame.minY), from: accSuper).y
            return y.isFinite ? Double(y) : nil
        }()
        // The trusted child height this pass, or nil to hold last-known-good.
        let computed: CGFloat? = containerTopY.flatMap { top in
            rawTerminalChildHeight(accessoryTopY: accessoryTopY, containerTopY: top,
                                   containerHeight: Double(bounds.height),
                                   accessoryHeight: accH,
                                   isFirstResponder: terminal.isFirstResponder).map { CGFloat($0) }
        }
        // Keyboard-down (not first responder) is a distinct, trustworthy "full height" case: the
        // keybar is gone, so the child fills the whole container. `rawTerminalChildHeight` returns
        // nil there (no accessory), so handle it explicitly rather than holding a stale keybar-up
        // height.
        let targetHeight: CGFloat? = {
            if !terminal.isFirstResponder { return bounds.height }   // keyboard down -> full
            if let computed { return computed }                       // trusted window-space value
            if lastChildHeight > 0 { return lastChildHeight }         // hold last-known-good
            return nil                                                // no trusted value yet -> leave as-is
        }()
        var applied = false
        if let targetHeight, abs(targetHeight - lastChildHeight) > 0.5 {
            lastChildHeight = targetHeight
            // The child is pinned top to the container top; its bottom constraint lifts it so its
            // height equals targetHeight: constant = -(bounds.height - targetHeight).
            bottomConstraint.constant = -(bounds.height - targetHeight)
            applied = true
        }

        // Bidirectional runtime invariant tripwire (device forensics guardrail): on a SETTLED pass
        // (we did not just change the constraint, so the child frame is re-solved), the child's
        // bottom should meet the keybar top. Log LOUD if it is BELOW the keybar top (rows hidden)
        // OR far ABOVE it (a gap), the two failure modes this whole arc fought. Uses the accessory's
        // window-space top converted back to container space as the reference (no bounds proxy).
        if !applied, let accTop = accessoryTopY, let top = containerTopY {
            let keybarTopInContainer = accTop - top          // keybar top in this container's space
            let childBottom = Double(terminal.frame.maxY)
            let delta = childBottom - keybarTopInContainer   // >0 = hidden rows, <0 = gap
            if abs(delta) > 2.0 {
                DebugLog.shared.log(.tmux,
                    "keybar-inset VIOLATION \(delta > 0 ? "HIDDEN" : "GAP") "
                    + "keybarTop=\(String(format: "%.0f", keybarTopInContainer)) "
                    + "childBottom=\(String(format: "%.0f", childBottom)) "
                    + "delta=\(String(format: "%.0f", delta))")
            }
        }

        // Standing layout-forensics line for the raw path (keep after the fix lands). The recurring
        // behind-keybar / gap-above-keybar bug (~7 fixes) came from the container's `bounds` being
        // ambiguous (sometimes keybar-included, sometimes -excluded) with no same-window height
        // signal to disambiguate; the fix instead drives the child from window-space geometry
        // (accessoryTopY - containerTopY). This logs both the inputs (containerTopY, accTopY, accH)
        // and the applied outcome (targetHeight, childFrame) so any recurrence is diagnosable from
        // one capture. `targetHeight=hold` means the window-space geometry was untrusted this pass
        // and the last-known-good height was held.
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let cf = terminal.frame
        let sa = safeAreaInsets
        let winB = win?.bounds ?? .zero
        let winSA = win?.safeAreaInsets ?? .zero
        var chain: [String] = []
        var v: UIView? = superview
        var depth = 0
        while let cur = v, depth < 6 {
            chain.append("\(String(describing: type(of: cur))):\(Int(cur.bounds.height))")
            v = cur.superview
            depth += 1
        }
        let klg = keyboardLayoutGuide.layoutFrame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "selfSA=(t\(Int(sa.top)),b\(Int(sa.bottom))) "
            + "win=\(Int(winB.width))x\(Int(winB.height)) winSA=(t\(Int(winSA.top)),b\(Int(winSA.bottom))) "
            + "fr=\(terminal.isFirstResponder) accH=\(String(format: "%.0f", accH)) "
            + "containerTopY=\(containerTopY.map { String(format: "%.0f", $0) } ?? "nil") "
            + "accTopY=\(accessoryTopY.map { String(format: "%.0f", $0) } ?? "nil") "
            + "targetHeight=\(targetHeight.map { String(format: "%.0f", Double($0)) } ?? "hold") "
            + "lastGood=\(String(format: "%.0f", Double(lastChildHeight))) applied=\(applied) "
            + "klgTop=\(Int(klg.minY)) klgH=\(Int(klg.height)) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height)) "
            + "chain=[\(chain.joined(separator: ">"))]")
    }

    /// The keybar (`inputAccessoryView`) height of the child terminal when it is first responder
    /// (iOS shows exactly that view's accessory). Returns -1 when the terminal is not first
    /// responder (keyboard down, no accessory). Feeds the window-space child-height trust guard.
    private func firstResponderKeybarHeight() -> CGFloat {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView as? KeybarInputAccessory else { return -1 }
        return acc.intrinsicContentSize.height
    }
}
