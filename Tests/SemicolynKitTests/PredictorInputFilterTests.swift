// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure extraction of predictor-relevant printable scalars from raw input bytes.
final class PredictorInputFilterTests: XCTestCase {
    private func s(_ str: String) -> [Unicode.Scalar] { Array(str.unicodeScalars) }

    // EP: plain printable ASCII passes through unchanged.
    func testPrintableAsciiPassesThrough() {
        XCTAssertEqual(predictorScalars(Array("ls".utf8)), s("ls"))
    }

    // BVA: space (0x20) is the low boundary — included.
    func testSpaceIsIncluded() {
        XCTAssertEqual(predictorScalars([0x20]), s(" "))
    }

    // BVA: tilde (0x7e) is the high boundary — included.
    func testTildeIsIncluded() {
        XCTAssertEqual(predictorScalars([0x7e]), s("~"))
    }

    // BVA: 0x1f (just below space) is excluded.
    func testBelowSpaceExcluded() {
        XCTAssertEqual(predictorScalars([0x1f]), [])
    }

    // BVA: 0x7f (DEL, just above tilde) is excluded.
    func testDelExcluded() {
        XCTAssertEqual(predictorScalars([0x7f]), [])
    }

    // Control bytes (newline, CR, ESC) are dropped; printable neighbours survive.
    func testControlBytesDroppedPrintableKept() {
        XCTAssertEqual(predictorScalars([0x61, 0x0d, 0x0a, 0x62]), s("ab"))
    }

    // Empty input ⇒ empty (no predictor-relevant scalars).
    func testEmptyInput() {
        XCTAssertEqual(predictorScalars([]), [])
    }
}
