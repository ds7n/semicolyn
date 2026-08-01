// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// A floating circular magnifier shown while dragging a selection handle. It snapshots the
/// region of the terminal under the finger, scales it up, and tracks the finger, clamped
/// inside the pane. Snapshotting is throttled so the tmux -CC repaint stream cannot choke it.
final class SelectionLoupeView: UIView {
    private let magnification: CGFloat = 1.4
    private let diameter: CGFloat = 110
    private let verticalOffset: CGFloat = 80
    private let imageLayer = CALayer()
    private var lastSnapshot: CFTimeInterval = 0
    private let minSnapshotInterval: CFTimeInterval = 1.0 / 30.0   // <= 30 snapshots/sec

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        layer.cornerRadius = diameter / 2
        layer.masksToBounds = true
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        imageLayer.frame = bounds
        imageLayer.contentsGravity = .center
        layer.addSublayer(imageLayer)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show/track the loupe around `point` (in `terminal`'s coordinate space), snapshotting
    /// the region under the finger. Adds self to `terminal.superview` on first show.
    func show(around point: CGPoint, in terminal: UIView) {
        guard let host = terminal.superview else { return }
        if superview !== host { host.addSubview(self) }
        isHidden = false

        // SemicolynKit's `loupeCenter` uses plain-Double geometry (no CoreGraphics on
        // Linux, see LoupeGeometry.swift); convert at this call boundary. Its inputs
        // (`terminal.bounds`, `point`) are both in terminal's own LOCAL coordinate
        // space, so the returned center is in that same local space too.
        let c = SemicolynKit.loupeCenter(
            finger: SelectionHandlePoint(x: Double(point.x), y: Double(point.y)),
            boundsWidth: Double(terminal.bounds.width), boundsHeight: Double(terminal.bounds.height),
            loupeWidth: Double(bounds.width), loupeHeight: Double(bounds.height),
            verticalOffset: Double(verticalOffset))
        let local = CGPoint(x: c.x, y: c.y)
        // `self.center` is interpreted in `self.superview`'s space (= host), which is
        // terminal's SIBLING space, not terminal's own space: they differ by
        // `terminal.frame.origin`, nonzero for any pane not at the container's
        // top-left (every pane but one in a multi-pane tmux -CC layout). Convert
        // local -> host space before assigning, or the loupe renders offset from
        // the finger by the pane's origin.
        self.center = host.convert(local, from: terminal)

        let now = CACurrentMediaTime()
        guard now - lastSnapshot >= minSnapshotInterval else { return }
        lastSnapshot = now
        // Snapshot a source region (diameter/magnification) centered on the finger, scaled up.
        let src = diameter / magnification
        let region = CGRect(x: point.x - src / 2, y: point.y - src / 2, width: src, height: src)
        let renderer = UIGraphicsImageRenderer(size: region.size)
        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -region.minX, y: -region.minY)
            terminal.layer.render(in: ctx.cgContext)
        }
        imageLayer.contents = image.cgImage
        imageLayer.contentsScale = magnification
    }

    func hide() { isHidden = true }
}
