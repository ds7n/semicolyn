// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure exponential-decay fling for the alt-screen scroll flick. The native `UIScrollView`
/// (normal-shell scroll) decelerates a flick for free; our synthetic wheel-event emitter
/// (Claude/vim/alt-screen) does not, because it only fires while the finger moves. This unit
/// models the same deceleration Apple uses so the App can keep emitting DECAYING wheel events
/// after the finger lifts, matching native feel.
///
/// Model: velocity decays as `v(t) = v0 · e^(−k·t)`, so the cumulative offset is
/// `offset(t) = (v0 / k) · (1 − e^(−k·t))`, converging to `v0 / k` as `t → ∞` (a bounded
/// fling, never runaway scroll). `k = decayRate` is derived from `UIScrollView`'s normal
/// deceleration rate (0.998 per ms) so the curve matches the momentum the user already gets
/// in the normal shell: `k = −1000 · ln(0.998) ≈ 2.0` per second.
public struct ScrollMomentum: Sendable {
    /// Continuous decay constant (per second). Started from `UIScrollView.DecelerationRate.normal`
    /// (0.998/ms -> k ~= 2.0) but the fling glided a touch too far on device (2026-07-19), so it
    /// was dialed back ~40% to a faster deceleration (0.9972/ms -> k ~= 2.8): a shorter, tighter
    /// glide. Higher = stops sooner.
    public static let decayRate: Double = -1000.0 * Foundation.log(0.9972)

    /// Minimum release speed (points/sec) that flings. Below this a lift is treated as a plain
    /// stop (no momentum) - matches the feel of releasing a slow drag. Feel-tuned.
    public static let minFlingVelocity: Double = 80.0

    /// Instantaneous velocity (points/sec) below which the fling is considered stopped, so the
    /// App's tick loop ends. Raised from 20 to 70 (2026-07-22): at ~1 wheel-line (~10pt) per
    /// event, a fling below ~70 pt/sec dribbles out slow single clicks with visible gaps (the
    /// alt-screen "grit"), so we end the fling crisply here instead of tailing off. A fast
    /// flick still carries; only the gritty slow tail is cut.
    public static let stopVelocity: Double = 70.0

    /// Release velocity (points/sec, signed: +down / −up as UIKit reports pan velocity).
    public let velocity: Double

    public init(velocity: Double) { self.velocity = velocity }

    /// Cumulative fling offset (points, signed) covered `t` seconds after release. 0 at t=0,
    /// converging to `velocity / decayRate`.
    public func offset(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        return (velocity / Self.decayRate) * (1 - Foundation.exp(-Self.decayRate * t))
    }

    /// Instantaneous velocity (points/sec) `t` seconds after release: `v0 · e^(−k·t)`.
    public func velocity(at t: Double) -> Double {
        Foundation.exp(-Self.decayRate * t) * velocity
    }

    /// True once the fling has effectively stopped: either the release speed never qualified
    /// (below `minFlingVelocity`, so it is finished at t=0) or the instantaneous speed has
    /// decayed below `stopVelocity`. The App loop stops ticking when this returns true.
    public func isFinished(at t: Double) -> Bool {
        if abs(velocity) < Self.minFlingVelocity { return true }
        return abs(velocity(at: t)) < Self.stopVelocity
    }
}
