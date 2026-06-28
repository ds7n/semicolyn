// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class BellStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFirstRingRequestsHaptic() {
        var b = BellStateMachine()
        XCTAssertTrue(b.ring(at: t0))
    }

    func testHapticThrottledWithin500ms() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        XCTAssertFalse(b.ring(at: t0.addingTimeInterval(0.3)))   // < 500ms gap
        XCTAssertTrue(b.ring(at: t0.addingTimeInterval(0.6)))    // > 500ms gap
    }

    func testIntensityHoldsAtPeakThenFades() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        XCTAssertEqual(b.intensity(at: t0), 1.0, accuracy: 0.0001)               // peak
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.4)), 1.0, accuracy: 0.0001) // hold edge
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.525)), 0.5, accuracy: 0.01)  // mid-fade
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.65)), 0.0, accuracy: 0.0001)  // faded out
    }

    func testIntensityZeroBeforeAnyRing() {
        XCTAssertEqual(BellStateMachine().intensity(at: t0), 0.0)
    }

    func testNewRingResetsTheHold() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        _ = b.ring(at: t0.addingTimeInterval(0.6))   // second ring re-arms peak
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.6)), 1.0, accuracy: 0.0001)
    }
}
