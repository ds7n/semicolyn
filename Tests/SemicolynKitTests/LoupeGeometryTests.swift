// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The loupe floats above the finger and stays fully inside the pane bounds.
///
/// Uses plain-Double geometry (`SelectionHandlePoint` + flat width/height/bounds Doubles),
/// not CoreGraphics: the Linux dev container has no CoreGraphics module, mirroring the
/// `SelectionHandlePoint`/`SelectionHandleRect` idiom from Task 6.
final class LoupeGeometryTests: XCTestCase {
    private let loupeWidth = 100.0
    private let loupeHeight = 100.0
    private let boundsWidth = 400.0
    private let boundsHeight = 800.0

    // EP: mid-screen finger -> loupe centered horizontally on finger, offset up.
    func testCentersAboveFinger() {
        let c = loupeCenter(finger: SelectionHandlePoint(x: 200, y: 400),
                             boundsWidth: boundsWidth, boundsHeight: boundsHeight,
                             loupeWidth: loupeWidth, loupeHeight: loupeHeight,
                             verticalOffset: 80)
        XCTAssertEqual(c.x, 200, accuracy: 0.001)
        XCTAssertEqual(c.y, 320, accuracy: 0.001)   // 400 - 80
    }

    // BVA: finger near the left edge clamps the loupe so its left stays >= 0.
    func testClampsLeft() {
        let c = loupeCenter(finger: SelectionHandlePoint(x: 10, y: 400),
                             boundsWidth: boundsWidth, boundsHeight: boundsHeight,
                             loupeWidth: loupeWidth, loupeHeight: loupeHeight,
                             verticalOffset: 80)
        XCTAssertEqual(c.x, 50, accuracy: 0.001)     // half of width (100/2)
    }

    // BVA: finger near the top clamps the loupe so its top stays >= 0.
    func testClampsTop() {
        let c = loupeCenter(finger: SelectionHandlePoint(x: 200, y: 20),
                             boundsWidth: boundsWidth, boundsHeight: boundsHeight,
                             loupeWidth: loupeWidth, loupeHeight: loupeHeight,
                             verticalOffset: 80)
        XCTAssertEqual(c.y, 50, accuracy: 0.001)     // half of height, cannot go above 0
    }

    // BVA: finger near the right edge clamps the loupe right to bounds max.
    func testClampsRight() {
        let c = loupeCenter(finger: SelectionHandlePoint(x: 395, y: 400),
                             boundsWidth: boundsWidth, boundsHeight: boundsHeight,
                             loupeWidth: loupeWidth, loupeHeight: loupeHeight,
                             verticalOffset: 80)
        XCTAssertEqual(c.x, 350, accuracy: 0.001)    // 400 - 50
    }
}
