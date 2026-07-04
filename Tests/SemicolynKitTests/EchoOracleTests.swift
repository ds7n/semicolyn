// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The value types + the scripted fake are the seam Kit tests drive; verify the
/// fake honors the protocol so the L1 tests that depend on it are trustworthy.
final class EchoOracleTests: XCTestCase {
    func testScriptedOracleReturnsScriptedCursorAndCell() {
        let oracle = ScriptedEchoOracle()
        oracle.nextCursor = EchoCursor(row: 2, col: 5)
        oracle.cellAt = { r, c in
            (r == 2 && c == 5) ? EchoCell(scalar: "k") : EchoCell(scalar: nil)
        }
        oracle.isAlternateBuffer = true

        XCTAssertEqual(oracle.cursor(), EchoCursor(row: 2, col: 5))
        XCTAssertEqual(oracle.cell(row: 2, col: 5), EchoCell(scalar: "k"))
        XCTAssertEqual(oracle.cell(row: 0, col: 0), EchoCell(scalar: nil))
        XCTAssertTrue(oracle.isAlternateBuffer)
    }

    func testEchoCellBlankIsNilScalar() {
        XCTAssertEqual(EchoCell(scalar: nil).scalar, nil)
        XCTAssertEqual(EchoCell(scalar: "*").scalar, "*")
    }
}
