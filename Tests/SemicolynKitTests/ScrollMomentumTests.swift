// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import SemicolynKit

/// Scroll-momentum fling: an exponential-decay model for the alt-screen scroll flick.
/// On pan release with velocity v0 (points/sec), the fling keeps producing scroll offset
/// that decelerates over time, so the App can emit decaying wheel events after the finger
/// lifts (native `UIScrollView` has this for free; our synthetic emitter does not).
final class ScrollMomentumTests: XCTestCase {

    // At t = 0 the fling has covered no distance yet.
    func testZeroTimeIsZeroOffset() {
        let m = ScrollMomentum(velocity: 2000)
        XCTAssertEqual(m.offset(at: 0), 0, accuracy: 0.0001)
    }

    // The total distance a fling covers is bounded (v0 / decayRate): as t -> infinity the
    // exponential decay integrates to a finite limit, never unbounded scroll.
    func testOffsetConvergesToVelocityOverDecay() {
        let v0 = 3000.0
        let m = ScrollMomentum(velocity: v0)
        // At a large t the offset is within 1% of the analytic limit v0/decayRate.
        let limit = v0 / ScrollMomentum.decayRate
        XCTAssertEqual(m.offset(at: 10), limit, accuracy: limit * 0.01)
    }

    // Monotonic + decelerating: distance grows over time, but each equal time-slice covers
    // LESS than the previous one (deceleration).
    func testDeceleratingSlices() {
        let m = ScrollMomentum(velocity: 2000)
        let slice1 = m.offset(at: 0.1) - m.offset(at: 0.0)
        let slice2 = m.offset(at: 0.2) - m.offset(at: 0.1)
        let slice3 = m.offset(at: 0.3) - m.offset(at: 0.2)
        XCTAssertGreaterThan(slice1, slice2)   // first slice covers more than second
        XCTAssertGreaterThan(slice2, slice3)   // and so on: decelerating
        XCTAssertGreaterThan(slice3, 0)        // still moving forward
    }

    // Sign is preserved: a negative release velocity (upward fling) flings the other way.
    func testNegativeVelocityFlingsNegative() {
        let up = ScrollMomentum(velocity: -2000)
        XCTAssertLessThan(up.offset(at: 0.1), 0)
        // Symmetric magnitude with the positive fling.
        let down = ScrollMomentum(velocity: 2000)
        XCTAssertEqual(up.offset(at: 0.1), -down.offset(at: 0.1), accuracy: 0.0001)
    }

    // `isFinished(at:)` reports when the fling's INSTANTANEOUS velocity has decayed below a
    // small threshold, so the App loop knows when to stop ticking. A fresh high-velocity
    // fling is not finished at t=0; a long-elapsed one is.
    func testIsFinishedAfterVelocityDecays() {
        let m = ScrollMomentum(velocity: 3000)
        XCTAssertFalse(m.isFinished(at: 0))    // just released, still fast
        XCTAssertTrue(m.isFinished(at: 5))     // long after release, essentially stopped
    }

    // A below-threshold release velocity is finished IMMEDIATELY (no fling for a slow lift):
    // the App uses this to skip momentum entirely on a gentle release.
    func testSlowReleaseIsImmediatelyFinished() {
        let slow = ScrollMomentum(velocity: ScrollMomentum.minFlingVelocity - 1)
        XCTAssertTrue(slow.isFinished(at: 0))
    }

    // A just-above-threshold release velocity DOES fling (boundary, min+1).
    func testAtThresholdReleaseFlings() {
        let m = ScrollMomentum(velocity: ScrollMomentum.minFlingVelocity + 1)
        XCTAssertFalse(m.isFinished(at: 0))
    }

    // D (2026-07-22): the fling must END while it is still moving at a few lines/sec, not
    // dribble out slow single wheel-clicks (the alt-screen grit). With the raised floor, a
    // fling that has decayed to ~60 pt/sec is considered finished (a ~6-line cell at ~10pt
    // is <1 line per few frames). Below the floor -> finished; comfortably above -> not.
    func testRaisedStopFloorEndsFlingWhileStillSlowMoving() {
        // A fling released fast enough to qualify, sampled at a time where its instantaneous
        // velocity has decayed to ~50 pt/sec, must now be finished (grit-cut).
        let m = ScrollMomentum(velocity: 1200)
        // find a t where velocity(at:) is ~50 pt/sec: v0 * e^(-k t) = 50.
        let k = ScrollMomentum.decayRate
        let tAtFifty = Foundation.log(1200.0 / 50.0) / k
        XCTAssertTrue(m.isFinished(at: tAtFifty),
                      "fling at ~50 pt/sec should be finished with the raised floor")
        // And it must NOT be finished while still moving briskly (~150 pt/sec).
        let tAtOneFifty = Foundation.log(1200.0 / 150.0) / k
        XCTAssertFalse(m.isFinished(at: tAtOneFifty),
                       "fling at ~150 pt/sec should still be running")
    }

    // The stop floor is the raised value (no silent retune back).
    func testStopVelocityFloorValue() {
        XCTAssertEqual(ScrollMomentum.stopVelocity, 70.0)
    }
}
