// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`). The `PaneTerminalView`
/// (a `UIScrollView`) is an Auto-Layout-pinned SUBVIEW; this container is what SwiftUI sizes.
/// The container reserves the keybar band via a stored bottom-constraint constant: the child is
/// pinned to the container's own leading/trailing/top/bottom edges, and the bottom constraint's
/// constant is set to `-reservation` each layout pass, lifting the child's bottom edge above the
/// keybar in every state (rotation, keyboard show/hide, app-switch). No keybar-top proxy signal
/// drives layout, and no `safeAreaLayoutGuide` / `additionalSafeAreaInsets` are used (the latter
/// is UIViewController-only and out of scope on a UIView).
///
/// This replaces the manual `usableH` computation + `terminal.frame = ...` framing that recurred as
/// the "rows behind the keybar" bug (~6 prior fixes): every one drove a hand-computed frame from a
/// proxy (`keyboardLayoutGuide` / converted accessory frame) that was wrong in some state. The
/// build-121 diagnostic proved the accessory's measured height (`accH`) is the one stable signal;
/// here it feeds the bottom-constraint constant and Auto Layout owns the rest.
/// See `docs/superpowers/specs/2026-08-08-keybar-safearea-reservation-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, pinned to the container's own edges (Auto Layout frames it).
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?
    /// Last reservation set, so we only mutate `bottomConstraint.constant` (which triggers a layout
    /// pass) when it actually changes, avoiding a layout feedback loop.
    private var lastReservation: CGFloat = -1
    /// The child's bottom pin, whose `constant` is driven to `-reservation` each layout pass to
    /// lift the child above the keybar band.
    private var bottomConstraint: NSLayoutConstraint!

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // Pin the child to self's own edges (NOT safeAreaLayoutGuide): the bottom constraint's
        // constant is driven by the keybar reservation set in layoutSubviews, so the child's
        // frame automatically excludes the keybar band in every state.
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
        // Reserve the keybar band via the bottom-constraint constant, sized by the one stable
        // signal (accH). Auto Layout then re-solves the child's frame against the new constant.
        // Update only on change so setting the constant (which itself re-triggers layout) does
        // not spin.
        let accH = Double(firstResponderKeybarHeight())
        let reservation = CGFloat(keybarSafeAreaReservation(accessoryHeight: accH,
                                                            isFirstResponder: terminal.isFirstResponder))
        let reservationChanged = abs(reservation - lastReservation) > 0.5
        if reservationChanged {
            lastReservation = reservation
            // Lift the child's bottom up by the keybar reservation via the stored bottom
            // constraint (additionalSafeAreaInsets is UIViewController-only; this is the
            // UIView-native equivalent). Auto Layout re-solves the child frame to
            // containerHeight - reservation; no manual framing.
            bottomConstraint.constant = -reservation
        }

        // Prong 3 (runtime invariant tripwire): the reserved keybar top is bounds.height minus the
        // reservation we just applied via the bottom constraint. If the child's bottom extends past
        // it, rows would render in the reserved band = the bug. Log it loud (default-on category)
        // instead of silently hiding a row.
        // Skip on a pass that just changed the reservation: the child frame has not been
        // re-solved against the new constraint constant yet this pass, so childBottom would still
        // reflect the pre-change frame and could spuriously exceed reservedTop for one frame; the
        // check runs on the next, settled pass instead.
        if !reservationChanged {
            let reservedTop = Double(bounds.height) - Double(reservation)
            let childBottom = Double(terminal.frame.maxY)
            if childBottom > reservedTop + 1.0 {
                DebugLog.shared.log(.tmux,
                    "keybar-inset VIOLATION reservedTop=\(String(format: "%.0f", reservedTop)) "
                    + "childBottom=\(String(format: "%.0f", childBottom)) "
                    + "over=\(String(format: "%.0f", childBottom - reservedTop))")
            }
        }

        // Comprehensive container-level geometry diagnostic (2026-08-08). The recurring
        // behind-keybar / gap-above-keybar bug (~7 fixes) is driven by the container's `bounds`
        // being UNSTABLE: after an app-switch SwiftUI hands a keybar-EXCLUDED bounds (e.g. 431),
        // on first connect a keybar-INCLUDED bounds (e.g. 499), and `safeAreaInsets` stays (0,0)
        // in both, so nothing at the UIView layer distinguishes the two regimes. This line logs
        // EVERY signal that could disambiguate them so any recurrence is diagnosable from one
        // capture: self bounds + safeAreaInsets, the window bounds + its safeAreaInsets, the full
        // superview chain heights (which SwiftUI host resized), the keyboardLayoutGuide frame, and
        // the child frame. Keep this even after the fix lands; it is the standing layout-forensics
        // line for the raw path.
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let cf = terminal.frame
        let sa = safeAreaInsets
        let win = window
        let winB = win?.bounds ?? .zero
        let winSA = win?.safeAreaInsets ?? .zero
        // Superview chain heights (which ancestor SwiftUI actually resized on the app-switch).
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
            + "reservation=\(String(format: "%.0f", Double(reservation))) "
            + "klgTop=\(Int(klg.minY)) klgH=\(Int(klg.height)) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height)) "
            + "chain=[\(chain.joined(separator: ">"))]")
    }

    /// The keybar (`inputAccessoryView`) height of the child terminal when it is first responder
    /// (iOS shows exactly that view's accessory). Returns -1 when the terminal is not first
    /// responder (keyboard down, no accessory). Feeds the safe-area reservation.
    private func firstResponderKeybarHeight() -> CGFloat {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView as? KeybarInputAccessory else { return -1 }
        return acc.intrinsicContentSize.height
    }
}
