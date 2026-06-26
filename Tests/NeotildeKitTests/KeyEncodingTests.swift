// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class KeyEncodingTests: XCTestCase {
    private func enc(_ k: KeyInput, _ m: KeyModifiers = .init(), app: Bool = false) -> [UInt8] {
        encodeKey(k, modifiers: m, applicationCursorKeys: app)
    }

    func testPlainKeys() {
        XCTAssertEqual(enc(.escape), [0x1b])
        XCTAssertEqual(enc(.tab), [0x09])
        XCTAssertEqual(enc(.enter), [0x0d])
        XCTAssertEqual(enc(.backspace), [0x7f])
        XCTAssertEqual(enc(.char("/")), [0x2f])
        XCTAssertEqual(enc(.char("~")), [0x7e])
    }

    func testControlLetters() {
        XCTAssertEqual(enc(.char("c"), .init(control: true)), [0x03])  // Ctrl+C
        XCTAssertEqual(enc(.char("a"), .init(control: true)), [0x01])
        XCTAssertEqual(enc(.char("C"), .init(control: true)), [0x03])  // case-insensitive
        XCTAssertEqual(enc(.char("z"), .init(control: true)), [0x1a])
    }

    func testControlSymbolsBoundaries() {
        XCTAssertEqual(enc(.char("@"), .init(control: true)), [0x00])  // NUL
        XCTAssertEqual(enc(.char(" "), .init(control: true)), [0x00])
        XCTAssertEqual(enc(.char("["), .init(control: true)), [0x1b]) // ESC
        XCTAssertEqual(enc(.char("\\"), .init(control: true)), [0x1c])
        XCTAssertEqual(enc(.char("_"), .init(control: true)), [0x1f])
        XCTAssertEqual(enc(.char("?"), .init(control: true)), [0x7f]) // DEL
    }

    func testControlWithoutMappingFallsBackToPlain() {
        // Ctrl+1 has no control form → send the plain char.
        XCTAssertEqual(enc(.char("1"), .init(control: true)), [0x31])
    }

    func testOptionPrefixesEscOnChars() {
        XCTAssertEqual(enc(.char("x"), .init(option: true)), [0x1b, 0x78])      // Alt+x
        XCTAssertEqual(enc(.char("c"), .init(control: true, option: true)), [0x1b, 0x03]) // Alt+Ctrl+C
    }

    func testShiftUppercasesLetterAndBackTabs() {
        XCTAssertEqual(enc(.char("a"), .init(shift: true)), [0x41])  // 'A'
        XCTAssertEqual(enc(.tab, .init(shift: true)), Array("\u{1b}[Z".utf8))  // back-tab
    }

    func testArrowsRespectCursorKeyMode() {
        XCTAssertEqual(enc(.arrow(.up)),  Array("\u{1b}[A".utf8))
        XCTAssertEqual(enc(.arrow(.left)), Array("\u{1b}[D".utf8))
        XCTAssertEqual(enc(.arrow(.up), app: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(enc(.arrow(.right), app: true), Array("\u{1b}OC".utf8))
    }

    func testFunctionKeysSS3AndCSI() {
        XCTAssertEqual(enc(.function(1)),  Array("\u{1b}OP".utf8))
        XCTAssertEqual(enc(.function(4)),  Array("\u{1b}OS".utf8))
        XCTAssertEqual(enc(.function(5)),  Array("\u{1b}[15~".utf8))
        XCTAssertEqual(enc(.function(10)), Array("\u{1b}[21~".utf8))
        XCTAssertEqual(enc(.function(11)), Array("\u{1b}[23~".utf8))  // note: skips 22
        XCTAssertEqual(enc(.function(12)), Array("\u{1b}[24~".utf8))
    }

    func testFunctionKeyOutOfRangeIsEmpty() {
        XCTAssertEqual(enc(.function(0)), [])
        XCTAssertEqual(enc(.function(13)), [])
    }
}
