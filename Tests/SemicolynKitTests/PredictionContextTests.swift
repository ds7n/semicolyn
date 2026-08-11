// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PredictionContextTests: XCTestCase {
    func testDefaultIsAllNil() {
        let c = PredictionContext()
        XCTAssertNil(c.foregroundProcess)
        XCTAssertNil(c.isAlternateScreen)
        XCTAssertNil(c.line)
        XCTAssertNil(c.cursorIndex)
        XCTAssertTrue(c.allSignalsNil)
    }

    func testAllSignalsNilFalseWhenAnyPresent() {
        XCTAssertFalse(PredictionContext(foregroundProcess: "zsh").allSignalsNil)
        XCTAssertFalse(PredictionContext(isAlternateScreen: false).allSignalsNil)
        XCTAssertFalse(PredictionContext(line: "hi").allSignalsNil)
        // cursorIndex alone still counts as a present signal.
        XCTAssertFalse(PredictionContext(cursorIndex: 0).allSignalsNil)
    }

    func testEquatable() {
        XCTAssertEqual(PredictionContext(foregroundProcess: "vim"),
                       PredictionContext(foregroundProcess: "vim"))
        XCTAssertNotEqual(PredictionContext(foregroundProcess: "vim"),
                          PredictionContext(foregroundProcess: "bash"))
    }
}
