// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import NeotildeKit

/// Renders a pulsed inset-glow overlay for the visual bell. Place as a
/// full-frame subview over the terminal/pane view; it is transparent when idle.
///
/// Drive pattern:
/// 1. Call `configure(color:)` once at setup (or when the theme changes).
/// 2. On each `bell()` delegate call: update your `BellStateMachine`, then call
///    `start(machine:)` — this arms/restarts the `CADisplayLink`.
/// 3. The display link self-terminates when `intensity` reaches 0.
///
/// The glow is drawn on a `CALayer` sublayer inset `borderInset` points from
/// each edge. The sublayer uses `borderWidth` + rounded corners + a matching
/// shadow to produce a soft "inner glow" that is visually distinct from the
/// 1.5pt hairline focus border on the parent `TerminalView`. `alpha` is applied
/// on the outer view so the glow fades each frame without re-layout.
///
/// UIKit/CALayer assumptions:
/// - `CADisplayLink(target:selector:)` + `.add(to: .main, forMode: .common)` —
///   standard UIKit (iOS 3.1+).
/// - `CALayer` sublayer with `borderColor`, `borderWidth`, `cornerRadius`,
///   `shadowColor`, `shadowRadius`, `shadowOpacity`, `shadowOffset` — standard
///   `CALayer` properties available since iOS 2.0.
/// - This file cannot be compiled on Linux; macOS CI validates it.
final class BellHaloView: UIView {
    // MARK: - Configuration

    /// Inset from the view edge where the glow sublayer is placed (points).
    private static let borderInset: CGFloat = 2
    /// Width of the glow border drawn on the sublayer.
    private static let borderWidth: CGFloat = 3
    /// Corner radius of the glow sublayer — rounds the inner ring slightly.
    private static let cornerRadius: CGFloat = 4
    /// Blur radius for the shadow that gives the glow its soft look.
    private static let glowRadius: CGFloat = 6

    private var machine: BellStateMachine = BellStateMachine()
    private var displayLink: CADisplayLink?

    /// Sublayer that carries the border glow, inset from the view edges.
    private let glowLayer = CALayer()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false   // pass-through; never intercepts touches
        backgroundColor = .clear
        alpha = 0

        glowLayer.borderWidth = Self.borderWidth
        glowLayer.borderColor = UIColor.clear.cgColor
        glowLayer.cornerRadius = Self.cornerRadius
        glowLayer.backgroundColor = UIColor.clear.cgColor
        // Shadow gives the border a soft outward glow rather than a hairline edge.
        glowLayer.shadowOpacity = 0.85
        glowLayer.shadowRadius = Self.glowRadius
        glowLayer.shadowOffset = .zero
        glowLayer.shadowColor = UIColor.clear.cgColor

        layer.addSublayer(glowLayer)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.borderInset
        glowLayer.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    // MARK: - API

    /// Set the halo glow color from the active theme.
    ///
    /// - Parameter color: Resolved `UIColor` from `theme.bell.edge`.
    func configure(color: UIColor) {
        glowLayer.borderColor = color.cgColor
        glowLayer.shadowColor = color.cgColor
    }

    /// Register a new bell ring and arm (or re-arm) the display link.
    ///
    /// - Parameter machine: The updated `BellStateMachine` after calling `ring(at:)`.
    func start(machine: BellStateMachine) {
        self.machine = machine
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        // Snap to peak immediately so the first frame is visible.
        alpha = 1
    }

    // MARK: - Display link

    @objc private func tick() {
        let i = machine.intensity(at: Date())
        alpha = CGFloat(i)
        if i == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
