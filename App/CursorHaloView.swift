// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Faint ~60pt disc around the terminal cursor — the engage target for the cursor-placement
/// drag (`docs/brainstorming-decisions.md` §"Cursor placement"). Non-interactive (the pan
/// gesture lives on the `TerminalView`); faintly visible at rest (~15%), brighter while a
/// drag is engaged. Style mirrors `BellHaloView` (a `CALayer` disc + soft shadow). This file
/// cannot be compiled on Linux; macOS CI validates it.
final class CursorHaloView: UIView {
    private static let restAlpha: CGFloat = 0.15
    private static let engagedAlpha: CGFloat = 0.32

    private let disc = CALayer()
    private var baseColor: UIColor = .white
    private var engaged = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false  // pass-through; never intercepts touches
        backgroundColor = .clear
        isHidden = true
        disc.shadowOffset = .zero
        disc.shadowRadius = 8
        disc.shadowOpacity = 1
        layer.addSublayer(disc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Set the halo color from the active theme (`theme.accent.primary`).
    func configure(color: UIColor) {
        baseColor = color
        apply()
    }

    /// Center the disc at `center` (this view's coords) with `radius`; reveals it.
    func place(center: CGPoint, radius: CGFloat) {
        // Disable implicit CALayer animation so the disc tracks the cursor without lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)
        disc.cornerRadius = radius
        CATransaction.commit()
        isHidden = false
        apply()
    }

    func hide() { isHidden = true }

    /// Brighten while a drag is engaged.
    func setEngaged(_ engaged: Bool) {
        self.engaged = engaged
        apply()
    }

    private func apply() {
        let a = engaged ? Self.engagedAlpha : Self.restAlpha
        disc.backgroundColor = baseColor.withAlphaComponent(a).cgColor
        disc.borderColor = baseColor.withAlphaComponent(min(1, a + 0.25)).cgColor
        disc.borderWidth = 1
        disc.shadowColor = baseColor.cgColor
    }
}
