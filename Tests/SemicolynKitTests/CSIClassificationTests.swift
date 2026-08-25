// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class CSIClassificationTests: XCTestCase {
    // Editing: arrows/home/end (A, B, C, D, H, F without private marker)
    func testArrowUpClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "A"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    func testArrowDownClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "B"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    func testArrowRightClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "C"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    func testArrowLeftClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "D"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    func testHomeKeyClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "H"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    func testEndKeyClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "F"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .editing)
    }

    // Editing with tilde: home/Delete/pgup/pgdn (param 1, 3, 5, 6)
    func testDeleteKeyClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 3)
        XCTAssertEqual(kind, .editing)
    }

    func testHomeKeyWithTildeClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 1)
        XCTAssertEqual(kind, .editing)
    }

    func testPageUpKeyClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 5)
        XCTAssertEqual(kind, .editing)
    }

    func testPageDownKeyClassifiedAsEditing() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 6)
        XCTAssertEqual(kind, .editing)
    }

    // Paste sequences
    func testPasteEnterClassifiedAsEnter() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 200)
        XCTAssertEqual(kind, .pasteEnter)
    }

    func testPasteExitClassifiedAsExit() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 201)
        XCTAssertEqual(kind, .pasteExit)
    }

    // Response/format: DA, SGR, cursor, etc.
    func testDAClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "c"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    func testSGRClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "m"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    func testMouseWithPrivateMarkerClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "M"), hadPrivateMarker: true, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    func testCursorPositionClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "R"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    // Unknown final byte -> responseOrFormat (default)
    func testUnknownFinalByteClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "z"), hadPrivateMarker: false, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    // Edge case: arrow with private marker should be response (not editing rule)
    func testArrowWithPrivateMarkerClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "A"), hadPrivateMarker: true, param0: nil)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    // Edge case: tilde with unexpected param should be response
    func testTildeWithUnexpectedParamClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "~"), hadPrivateMarker: false, param0: 99)
        XCTAssertEqual(kind, .responseOrFormat)
    }

    // Edge case: param0 200/201 without tilde should be response
    func testPasteParamWithoutTildeClassifiedAsResponseOrFormat() {
        let kind = csiKind(finalByte: UInt8(ascii: "m"), hadPrivateMarker: false, param0: 200)
        XCTAssertEqual(kind, .responseOrFormat)
    }
}
