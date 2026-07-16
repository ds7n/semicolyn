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

    // EP: clear rightward horizontal drag, multi-window tmux → PREVIOUS window (-1).
    // Content-follows-finger: swiping content rightward reveals the window to its left.
    func testHorizontalRightSwitchesPrev() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: clear leftward horizontal drag, multi-window tmux → NEXT window (+1).
    func testHorizontalLeftSwitchesNext() {
        XCTAssertEqual(GestureClassifier.classify(dx: -(dz + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
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

    // BVA: just past the dead-zone on a PURE horizontal axis (dy=0, tmux) → switch
    // (pure horizontal is infinitely dominant, well past the switch ratio). NOTE: the
    // dead-zone is Euclidean, so dy=0 needs dx just past dz.
    func testJustPastDeadZoneHorizontal() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 0.1, dy: 0, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))   // rightward -> previous
    }

    // Diagonal near-45°, vertical slightly dominant → scroll (axis by dominance).
    func testDiagonalVerticalDominantScrolls() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 30, dy: dz + 45, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // BIAS-TO-SCROLL: a slightly-horizontal-dominant drag (dx ≈ 1.36× dy, below the
    // switch-dominance ratio) now SCROLLS instead of switching — this is the accidental
    // "swipe into the wrong window during a vertical scroll" case from device testing.
    func testSlightlyHorizontalDragScrollsNotSwitches() {
        // dx=60, dy=44 → ratio 1.36 < switchDominanceRatio (1.7) → scroll.
        XCTAssertEqual(GestureClassifier.classify(dx: 60, dy: 44, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // A clearly-horizontal drag (dx > ratio × dy) still switches windows in tmux.
    func testClearlyHorizontalDragSwitches() {
        // dx=90, dy=20 → ratio 4.5 ≥ 1.7 → switch. Rightward -> previous (-1).
        XCTAssertEqual(GestureClassifier.classify(dx: 90, dy: 20, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // BVA: just BELOW the switch-dominance ratio → scroll.
    func testJustBelowSwitchRatioScrolls() {
        let r = GestureClassifier.switchDominanceRatio
        // dx just under r×dy (dy=30 → threshold 30r; use 30r - 3) → scroll.
        XCTAssertEqual(GestureClassifier.classify(dx: 30 * r - 3, dy: 30, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // BVA: just ABOVE the switch-dominance ratio (tmux) → switch.
    func testJustAboveSwitchRatioSwitches() {
        let r = GestureClassifier.switchDominanceRatio
        // dx just over r×dy → switch. Rightward -> previous (-1).
        XCTAssertEqual(GestureClassifier.classify(dx: 30 * r + 3, dy: 30, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // A clearly-horizontal drag in RAW (non-multi-window) still falls through to scroll.
    func testClearlyHorizontalInRawStillScrolls() {
        XCTAssertEqual(GestureClassifier.classify(dx: 90, dy: 20, isMultiWindowTmux: false),
                       .scrollVertical)
    }
}
