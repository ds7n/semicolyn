// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Release decision: commit the switch if dragged past the distance fraction OR flicked
/// past the velocity threshold; otherwise spring back. Direction sign is content-follows-
/// finger (rightward -> previous / -1, leftward -> next / +1).
final class SwitchCommitDecisionTests: XCTestCase {
    private let width = 400.0
    private let vel0 = 0.0   // no flick

    // EP: short slow drag (below distance, no velocity) -> spring back.
    func testShortSlowDragSpringsBack() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: 40, width: width, velocity: vel0),
                       .springBack)
    }

    // EP: dragged well past the distance fraction, rightward -> commit PREVIOUS (-1).
    func testPastDistanceRightCommitsPrev() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: 0.6 * width, width: width, velocity: vel0),
                       .commit(delta: -1))
    }

    // EP: dragged well past the distance fraction, leftward -> commit NEXT (+1).
    func testPastDistanceLeftCommitsNext() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -0.6 * width, width: width, velocity: vel0),
                       .commit(delta: +1))
    }

    // Distance-or-velocity: a SHORT but FAST leftward flick still commits NEXT (+1).
    func testShortFastFlickCommits() {
        let v = SwitchCommitDecision.velocityThreshold + 100   // clearly past
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -0.1 * width, width: width, velocity: -v),
                       .commit(delta: +1))
    }

    // BVA: just BELOW the distance fraction with no flick -> spring back.
    func testJustBelowDistanceSpringsBack() {
        let dx = SwitchCommitDecision.distanceFraction * width - 1
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: dx, width: width, velocity: vel0),
                       .springBack)
    }

    // BVA: just ABOVE the distance fraction (rightward) -> commit previous (-1).
    func testJustAboveDistanceCommits() {
        let dx = SwitchCommitDecision.distanceFraction * width + 1
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: dx, width: width, velocity: vel0),
                       .commit(delta: -1))
    }

    // A flick BELOW the velocity threshold AND below distance -> spring back (neither trips).
    func testSlowShortDragBelowBothSpringsBack() {
        let v = SwitchCommitDecision.velocityThreshold - 50
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -20, width: width, velocity: -v),
                       .springBack)
    }
}
