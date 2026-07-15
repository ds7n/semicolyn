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

    // THE build-42 bug: SwiftTerm's lazily-created selection/mouse pan must NOT
    // co-recognize with the scroll pan (either order). When it did, a plain vertical
    // drag was driven as a text selection by SwiftTerm's own pan (device trace
    // 2026-07-13: zero `.gesture` logs during the drag → our handlers never ran →
    // the selection pan won arbitration). Excluding the pair lets the scroll pan
    // cancel it on movement, the same mechanism that fixed long-press.
    func testSelectionPanAndScrollPanAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.selectionPan, .scrollPan))
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.scrollPan, .selectionPan))
    }

    // The selection pan doesn't fight taps (a tap that activated a selection is fine)
    // or pinch; only the scroll pan must beat it.
    func testSelectionPanCoexistsWithTapsAndPinch() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.selectionPan, .tap))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.selectionPan, .pinch))
    }

    // Our alt-screen drag pan must NOT co-recognize with the long-press (either order):
    // a held-then-drag on an alt-screen pane must emit arrows, not anchor a selection —
    // the same hazard the scroll-pan/long-press exclusion fixes. Making the pairing
    // exclusive lets the alt pan cancel the long-press on motion (build-47 fix).
    func testAltScreenPanAndLongPressAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.altScreenPan, .longPress))
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.longPress, .altScreenPan))
    }

    // The alt-screen pan and the native scroll pan are never both live (mode-gated:
    // the alt pan is enabled ONLY in `.appOwnsInput`, where `isScrollEnabled = false`
    // parks the scroll pan). The policy leaves this pairing permissive because it can't
    // actually co-occur; assert the current (non-excluded) contract so a future change
    // to exclude it is a deliberate, test-visible decision.
    func testAltScreenPanAndScrollPanCoexistInPolicy() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.altScreenPan, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.scrollPan, .altScreenPan))
    }

    // The alt-screen pan doesn't fight taps or pinch (a two-finger pinch-zoom while
    // alt-screen scrolling, or a tap, must still resolve).
    func testAltScreenPanCoexistsWithTapsAndPinch() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.altScreenPan, .tap))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.altScreenPan, .pinch))
    }

    // Exactly three pairings are excluded; nothing else is.
    func testOnlyKnownPairingsAreExcluded() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.scrollPan, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.longPress, .pinch))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.other, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.longPress, .tap))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.altScreenPan, .other))
        // The three excluded pairings, for the record:
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.longPress, .scrollPan))
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.selectionPan, .scrollPan))
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.altScreenPan, .longPress))
    }
}
