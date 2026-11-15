// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeContrastTests: XCTestCase {
    func testBlackOnWhiteIs21() {
        XCTAssertEqual(contrastRatio(ThemeColor("#000000"), ThemeColor("#FFFFFF")), 21, accuracy: 0.01)
    }

    func testEqualColorsIs1() {
        XCTAssertEqual(contrastRatio(ThemeColor("#7F7F7F"), ThemeColor("#7F7F7F")), 1, accuracy: 0.0001)
    }

    func testSymmetric() {
        XCTAssertEqual(contrastRatio(ThemeColor("#FF6F5E"), ThemeColor("#05070B")),
                       contrastRatio(ThemeColor("#05070B"), ThemeColor("#FF6F5E")), accuracy: 0.0001)
    }

    /// #767676 on white is the canonical "just passes AA" gray (4.54:1).
    func testKnownPair() {
        XCTAssertEqual(contrastRatio(ThemeColor("#767676"), ThemeColor("#FFFFFF")), 4.54, accuracy: 0.01)
    }

    func testRelativeLuminanceEndpoints() {
        XCTAssertEqual(ThemeColor("#FFFFFF").relativeLuminance, 1, accuracy: 0.0001)
        XCTAssertEqual(ThemeColor("#000000").relativeLuminance, 0, accuracy: 0.0001)
    }

    func testCompositedHalfBlackOverWhite() {
        XCTAssertEqual(ThemeColor("#000000", opacity: 0.5).composited(over: ThemeColor("#FFFFFF")),
                       ThemeColor("#808080"))
    }

    func testTranslucentContrastUsesComposite() {
        XCTAssertEqual(contrastRatio(ThemeColor("#000000", opacity: 0.0), ThemeColor("#FFFFFF")), 1, accuracy: 0.0001)
    }
}
