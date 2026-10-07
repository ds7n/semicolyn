// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// SGR 1006 left-click = a press (button 0, final 'M') then a release (final 'm')
/// at the same 1-based cell. Mirrors the existing SGR wheel encoder format
/// (ArrowEncoding.encodeWheelRun): ESC [ < Cb ; col ; row <M|m>.
final class SGRMouseClickTests: XCTestCase {
    func testLeftClickPressThenRelease() {
        let bytes = sgrMouseClick(col: 3, row: 5)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[<0;3;5M\u{1b}[<0;3;5m")
    }

    // BVA: coordinate 1 (the minimum valid 1-based cell).
    func testClickAtOrigin() {
        XCTAssertEqual(String(decoding: sgrMouseClick(col: 1, row: 1), as: UTF8.self),
                       "\u{1b}[<0;1;1M\u{1b}[<0;1;1m")
    }

    // Large coordinates render as decimal, no clamping in the pure encoder.
    func testLargeCoordinates() {
        XCTAssertEqual(String(decoding: sgrMouseClick(col: 200, row: 60), as: UTF8.self),
                       "\u{1b}[<0;200;60M\u{1b}[<0;200;60m")
    }
}
