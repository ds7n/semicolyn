// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The result of releasing a live window-switch drag.
public enum SwitchOutcome: Equatable, Sendable {
    /// Commit the switch by `delta` (rightward release -> previous / -1, leftward -> next / +1).
    case commit(delta: Int)
    /// Snap the current window back (drag too short and not flicked).
    case springBack
}

/// Pure release decision for the live finger-drag window switch. Commit if the drag
/// travelled past `distanceFraction` of the pane width OR was released with speed past
/// `velocityThreshold` (a short fast flick still switches, matching iOS paging); else
/// spring back. Direction is content-follows-finger.
public struct SwitchCommitDecision: Sendable {
    /// Fraction of pane width the drag must pass to commit on distance alone.
    public static let distanceFraction: Double = 0.4
    /// Release speed (points/sec, absolute) that commits regardless of distance.
    public static let velocityThreshold: Double = 500

    public static func resolve(dx: Double, width: Double, velocity: Double) -> SwitchOutcome {
        guard width > 0, dx != 0 else { return .springBack }
        let pastDistance = abs(dx) >= distanceFraction * width
        // Only a flick IN THE DRAG DIRECTION counts (sign agreement); a fast bounce-back
        // in the opposite direction must not commit.
        let flicked = abs(velocity) >= velocityThreshold && (velocity < 0) == (dx < 0)
        guard pastDistance || flicked else { return .springBack }
        return .commit(delta: dx > 0 ? -1 : +1)
    }
}
