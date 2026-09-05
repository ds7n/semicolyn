// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxPrefixTests: XCTestCase {
    // parseTmuxPrefix: EP + BVA on the C-a..C-z control map
    func testParseCb() { XCTAssertEqual(parseTmuxPrefix("C-b"), 0x02) }
    func testParseCa() { XCTAssertEqual(parseTmuxPrefix("C-a"), 0x01) }
    func testParseCz() { XCTAssertEqual(parseTmuxPrefix("C-z"), 0x1a) }
    func testParseTrimsWhitespace() { XCTAssertEqual(parseTmuxPrefix("  C-a \n"), 0x01) }
    func testParseNoneIsNil() { XCTAssertNil(parseTmuxPrefix("None")) }
    func testParseEmptyIsNil() { XCTAssertNil(parseTmuxPrefix("")) }
    func testParseMultiKeyIsNil() { XCTAssertNil(parseTmuxPrefix("C-a C-b")) }
    func testParseGarbageIsNil() { XCTAssertNil(parseTmuxPrefix("hello")) }
    func testParseNonControlIsNil() { XCTAssertNil(parseTmuxPrefix("M-a")) }   // meta, not control: nil (Phase 1 supports C- only)
    func testParseUppercaseLetterMapsToControl() { XCTAssertEqual(parseTmuxPrefix("C-A"), 0x01) }  // case-insensitive letter

    // parseSemicolynPrefixSentinel
    func testSentinelExtractsValue() {
        XCTAssertEqual(parseSemicolynPrefixSentinel("SEMICOLYN_PREFIX=C-a\r"), "C-a")
    }
    func testSentinelEmbeddedInOutput() {
        XCTAssertEqual(parseSemicolynPrefixSentinel("junk\r\nSEMICOLYN_PREFIX=C-b\rmore"), "C-b")
    }
    func testSentinelAbsentIsNil() {
        XCTAssertNil(parseSemicolynPrefixSentinel("no marker here"))
    }
    func testSentinelTrailingSpacesTrimmed() {
        XCTAssertEqual(parseSemicolynPrefixSentinel("SEMICOLYN_PREFIX=C-a  \r"), "C-a")
    }

    // prefixKeySequence
    func testPrefixKeyNextWindow() {
        XCTAssertEqual(prefixKeySequence(prefix: 0x02, key: "n"), [0x02, 0x6e])
    }
    func testPrefixKeyZoomWithCa() {
        XCTAssertEqual(prefixKeySequence(prefix: 0x01, key: "z"), [0x01, 0x7a])
    }

    // prefixCommandSequence
    func testPrefixCommandSelectPane() {
        let seq = prefixCommandSequence(prefix: 0x02, command: "select-pane -t %3")
        var expected: [UInt8] = [0x02, 0x3a]   // prefix, ':'
        expected += Array("select-pane -t %3".utf8)
        expected += [0x0d]                      // Enter
        XCTAssertEqual(seq, expected)
    }
}
