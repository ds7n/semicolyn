// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class GestureSimultaneityTests: XCTestCase {
    // THE bug: long-press must NOT co-recognize with the scroll pan (either order).
    func testLongPressAndScrollPanAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.longPress, .scrollPan))
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.scrollPan, .longPress))
    }

    // Pinch must still coexist with the pan (2-finger vs 1-finger: a stray second
    // finger can't kill scroll) — the coexistence the original delegate wanted.
    func testPinchCoexistsWithScrollPan() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.pinch, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.scrollPan, .pinch))
    }

    // Pinch coexists with long-press too (2-finger zoom vs a still-finger press).
    func testPinchCoexistsWithLongPress() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.pinch, .longPress))
    }

    // Taps coexist with everything (they resolve on lift, don't fight the pan).
    func testTapsCoexist() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.tap, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.tap, .longPress))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.tap, .pinch))
    }

    // Only the long-press↔pan pairing is excluded; nothing else is.
    func testOnlyLongPressPanIsExcluded() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.scrollPan, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.longPress, .pinch))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.other, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.longPress, .tap))
    }
}
