// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxIDTests: XCTestCase {
    func testPaneIDParsesValidToken() {
        XCTAssertEqual(PaneID(token: "%7"), PaneID(raw: 7))
    }
    func testWindowIDParsesValidToken() {
        XCTAssertEqual(WindowID(token: "@0"), WindowID(raw: 0))
    }
    func testSessionIDParsesValidToken() {
        XCTAssertEqual(SessionID(token: "$13"), SessionID(raw: 13))
    }
    func testWrongSigilIsRejected() {
        XCTAssertNil(PaneID(token: "@7"))   // pane needs %
        XCTAssertNil(WindowID(token: "%0")) // window needs @
    }
    func testNonNumericRemainderIsRejected() {
        XCTAssertNil(PaneID(token: "%x"))
        XCTAssertNil(PaneID(token: "%"))    // empty remainder
    }
}
