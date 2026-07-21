// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Restore the pre-drag scroll offset ONLY when the drag locks to a window switch
/// (the native scroll pan nudged the buffer during the dead-zone before we locked).
/// Scroll and still-pending drags keep their live offset.
final class ScrollResidueDecisionTests: XCTestCase {
    // EP: switch-locked -> restore to the saved offset exactly.
    func testSwitchRestoresToSavedOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .switchWindow(delta: -1), savedX: 3, savedY: 42),
            .restore(toX: 3, toY: 42))
    }

    // EP: the delta sign does not change the restore target (both switch directions restore).
    func testSwitchOtherDirectionAlsoRestores() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .switchWindow(delta: +1), savedX: 0, savedY: 7),
            .restore(toX: 0, toY: 7))
    }

    // EP: scroll axis -> keep the live offset (native scroll must run free).
    func testScrollKeepsLiveOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .scroll, savedX: 3, savedY: 42),
            .keep)
    }

    // BVA: still-pending (inside dead-zone) -> keep (no decision yet).
    func testPendingKeepsLiveOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .pending, savedX: 3, savedY: 42),
            .keep)
    }
}
