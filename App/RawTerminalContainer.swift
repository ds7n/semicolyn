// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`). The `PaneTerminalView`
/// (a `UIScrollView`) is an Auto-Layout-pinned SUBVIEW; this container is what SwiftUI sizes.
/// The container reserves the keybar band as a bottom safe-area inset and pins
/// the child to `safeAreaLayoutGuide`, so UIKit keeps the terminal above the keybar automatically in
/// every state (rotation, keyboard show/hide, app-switch). No keybar-top proxy signal drives layout.
///
/// This replaces the manual `usableH` computation + `terminal.frame = ...` framing that recurred as
/// the "rows behind the keybar" bug (~6 prior fixes): every one drove a hand-computed frame from a
/// proxy (`keyboardLayoutGuide` / converted accessory frame) that was wrong in some state. The
/// build-121 diagnostic proved the accessory's measured height (`accH`) is the one stable signal;
/// here it feeds `additionalSafeAreaInsets.bottom` and UIKit owns the rest.
/// See `docs/superpowers/specs/2026-08-08-keybar-safearea-reservation-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, pinned to `safeAreaLayoutGuide` (UIKit frames it).
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?
    /// Last reservation set, so we only mutate `additionalSafeAreaInsets` (which triggers a layout
    /// pass) when it actually changes, avoiding a layout feedback loop.
    private var lastReservation: CGFloat = -1

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // Pin the child to the safe-area guide (NOT self.bounds): UIKit shrinks the guide by
        // `additionalSafeAreaInsets.bottom` (the keybar reservation set in layoutSubviews), so the
        // child's frame automatically excludes the keybar band in every state.
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reserve the keybar band via safe area, sized by the one stable signal (accH). UIKit then
        // shrinks safeAreaLayoutGuide and re-frames the pinned child. Update only on change so
        // setting the inset (which itself re-triggers layout) does not spin.
        let accH = Double(firstResponderKeybarHeight())
        let reservation = CGFloat(keybarSafeAreaReservation(accessoryHeight: accH,
                                                            isFirstResponder: terminal.isFirstResponder))
        let reservationChanged = abs(reservation - lastReservation) > 0.5
        if reservationChanged {
            lastReservation = reservation
            additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: reservation, right: 0)
            // Setting the inset invalidates layout; the next pass reads the settled child frame.
        }

        // Prong 3 (runtime invariant tripwire): the reserved keybar top is UIKit's OWN post-layout
        // truth, bounds.height - safeAreaInsets.bottom (safeAreaInsets already reflects our
        // additional inset). If the child's bottom extends past it, rows would render in the reserved
        // band = the bug. Log it loud (default-on category) instead of silently hiding a row.
        // Skip on a pass that just changed the reservation: the child frame has not been
        // re-solved against the new inset yet this pass, so childBottom would still reflect the
        // pre-change frame and could spuriously exceed reservedTop for one frame; the check runs
        // on the next, settled pass instead.
        if !reservationChanged {
            let reservedTop = Double(bounds.height) - Double(safeAreaInsets.bottom)
            let childBottom = Double(terminal.frame.maxY)
            if childBottom > reservedTop + 1.0 {
                DebugLog.shared.log(.tmux,
                    "keybar-inset VIOLATION reservedTop=\(String(format: "%.0f", reservedTop)) "
                    + "childBottom=\(String(format: "%.0f", childBottom)) "
                    + "over=\(String(format: "%.0f", childBottom - reservedTop))")
            }
        }

        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let cf = terminal.frame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "saInsetBottom=\(String(format: "%.0f", Double(safeAreaInsets.bottom))) "
            + "fr=\(terminal.isFirstResponder) accH=\(String(format: "%.0f", accH)) "
            + "reservation=\(String(format: "%.0f", Double(reservation))) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height))")
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
