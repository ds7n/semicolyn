// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Axis-lock classification of a terminal pan: vertical → scroll, horizontal →
/// tmux window switch (only when multi-window tmux, else scroll), sub-dead-zone → none.
final class GestureClassifierTests: XCTestCase {
    private let dz = GestureClassifier.deadZonePoints

    // EP: clear vertical drag → scroll (both tmux and raw).
    func testVerticalDragScrollsInTmux() {
        XCTAssertEqual(GestureClassifier.classify(dx: 2, dy: dz + 40, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    func testVerticalDragScrollsInRaw() {
        XCTAssertEqual(GestureClassifier.classify(dx: 2, dy: dz + 40, isMultiWindowTmux: false),
                       .scrollVertical)
    }

    // EP: clear rightward horizontal drag, multi-window tmux → next window (+1).
    func testHorizontalRightSwitchesNext() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // EP: clear leftward horizontal drag, multi-window tmux → previous window (-1).
    func testHorizontalLeftSwitchesPrev() {
        XCTAssertEqual(GestureClassifier.classify(dx: -(dz + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: horizontal drag, NOT multi-window tmux → falls through to scroll.
    func testHorizontalInRawFallsThroughToScroll() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 40, dy: 2, isMultiWindowTmux: false),
                       .scrollVertical)
    }

    // BVA: total movement below the dead-zone → none (no classification yet).
    func testSubDeadZoneIsNone() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz * 0.4, dy: dz * 0.4, isMultiWindowTmux: true),
                       .none)
    }

    // BVA: just past the dead-zone on the vertical axis → scroll (boundary+1).
    func testJustPastDeadZoneVertical() {
        XCTAssertEqual(GestureClassifier.classify(dx: 0, dy: dz + 0.1, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // BVA: just past the dead-zone on the horizontal axis (tmux) → switch.
    func testJustPastDeadZoneHorizontal() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 0.1, dy: 0, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // Diagonal near-45°, vertical slightly dominant → scroll (axis by dominance).
    func testDiagonalVerticalDominantScrolls() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 30, dy: dz + 45, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // Diagonal near-45°, horizontal slightly dominant (tmux) → switch.
    func testDiagonalHorizontalDominantSwitches() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 45, dy: dz + 30, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }
}
